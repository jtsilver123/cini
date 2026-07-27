-- Hardening pass over the 0130/0131 retention features (mirrors prod
-- migration `retention_hardening`). Seven fixes found auditing that batch:
--
-- 1) FREEZE FARMING. rank_insert's earn branch fired on `v_week_ranks = 3`,
--    but a re-rank DELETEs and re-INSERTs the row, so its created_at was
--    re-stamped to now() — the count could hit exactly 3 again and again.
--    A user who ranked nothing new could re-order 3 old titles and earn a
--    freeze. Now: created_at is CARRIED THROUGH the re-insert (so it means
--    "first ranked at" for every consumer), and the earn is a once-per-week
--    latch on profiles.last_freeze_week rather than an exact-count trigger.
--
-- 2) WEEKLY RECAP COUNTED RE-ORDERS as new ranks (same re-stamped
--    created_at) — "You ranked 5 titles" for a week of pure re-ordering.
--    Fixed by the same created_at carry-through.
--
-- 3) The two new cron kinds were NOT exempt from notify_push's 5/hr-15/day
--    cap, so the most engaged users — the ones with the most notification
--    volume — silently never got the push. Both are cron-paced (≤1/day and
--    ≤1/week per user), so exempting them can't re-open the buzz flood.
--
-- 4) A recap for a user with no ranks of their own read as a mid-sentence
--    fragment: "friends ranked 12". Each segment now stands alone.
--
-- 5) The nudge window ([-36h, -3h]) meant ONE failed cron run dropped a
--    21-hour band of watch plans forever. Widened to 72h — the existing
--    7-day dedupe and the not-yet-ranked check still guarantee at most one.
--
-- 6) crew_add_member notified even when the member was already there
--    (`on conflict do nothing` + an unconditional notification insert) —
--    repeatable push spam. Now gated on an actual insert.
--
-- 7) crew_add_member/crew_create checked their caps then inserted with no
--    lock, so two simultaneous adds could take a crew to 9 members. Both
--    now take an advisory lock first, like rank_insert does.

alter table public.profiles
  add column if not exists last_freeze_week date;

-- ------------------------------------------------------------- rank_insert

create or replace function public.rank_insert(
    p_movie_id integer,
    p_bucket text,
    p_position integer,
    p_watch_date date default null,
    p_stealth boolean default false,
    p_tz text default 'UTC'
) returns public.rankings
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_kind text;
    v_old rankings%rowtype;
    v_row rankings%rowtype;
    v_count integer;
    v_pos integer;
    v_tz text;
    v_week date;
    v_week_ranks integer;
    v_was_new boolean := true;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if p_bucket not in ('loved', 'fine', 'disliked') then
        raise exception 'invalid bucket %', p_bucket;
    end if;

    v_tz := coalesce((select name from pg_timezone_names where name = p_tz limit 1), 'UTC');
    v_week := date_trunc('week', now() at time zone v_tz)::date;

    select media_kind into v_kind from movies where tmdb_id = p_movie_id;
    if v_kind is null then raise exception 'unknown movie %', p_movie_id; end if;

    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    select * into v_old from rankings where user_id = v_user and movie_id = p_movie_id;
    if found then
        v_was_new := false;
        delete from rankings where id = v_old.id;
        update rankings r set position = r.position - 1
        from movies m
        where m.tmdb_id = r.movie_id and r.user_id = v_user
          and r.bucket = v_old.bucket and m.media_kind = v_kind
          and r.position > v_old.position;
        if v_old.bucket <> p_bucket then
            perform rescore_bucket(v_user, v_old.bucket, v_kind);
        end if;
    end if;

    select count(*) into v_count
    from rankings r join movies m on m.tmdb_id = r.movie_id
    where r.user_id = v_user and r.bucket = p_bucket and m.media_kind = v_kind;
    v_pos := least(greatest(p_position, 0), v_count);

    update rankings r set position = r.position + 1
    from movies m
    where m.tmdb_id = r.movie_id and r.user_id = v_user
      and r.bucket = p_bucket and m.media_kind = v_kind
      and r.position >= v_pos;

    -- created_at is CARRIED THROUGH a re-rank: it means "first ranked at",
    -- so re-ordering can't masquerade as this-week activity for the freeze
    -- counter, the weekly recap, or the Date-added sort.
    insert into rankings (user_id, movie_id, bucket, position, score, watch_date,
                          watched_with, created_at)
    values (v_user, p_movie_id, p_bucket, v_pos, 0,
            coalesce(p_watch_date, v_old.watch_date),
            coalesce(v_old.watched_with, '{}'),
            coalesce(v_old.created_at, now()))
    returning * into v_row;

    perform rescore_bucket(v_user, p_bucket, v_kind);

    delete from watchlist where user_id = v_user and movie_id = p_movie_id;

    -- Ranks that FIRST landed in the user's current local week.
    select count(*) into v_week_ranks
    from rankings r
    where r.user_id = v_user
      and (r.created_at at time zone v_tz)::date >= v_week;

    update profiles p set
        streak_weeks = case
            when p.last_logged_week = v_week then p.streak_weeks
            when p.last_logged_week = v_week - 7 then p.streak_weeks + 1
            -- Missed exactly one week with a freeze banked: the freeze covers
            -- the gap — streak survives.
            when p.last_logged_week = v_week - 14
                 and coalesce(p.streak_freezes, 0) > 0 then p.streak_weeks + 1
            else 1 end,
        streak_freezes = greatest(0, least(2, case
            when p.last_logged_week = v_week - 14
                 and coalesce(p.streak_freezes, 0) > 0 then coalesce(p.streak_freezes, 0) - 1
            -- Earn at 3+, ONCE per week (a latch, not an exact-count trigger).
            when v_week_ranks >= 3 and p.last_freeze_week is distinct from v_week
                then coalesce(p.streak_freezes, 0) + 1
            else coalesce(p.streak_freezes, 0) end)),
        last_freeze_week = case
            when v_week_ranks >= 3 and p.last_freeze_week is distinct from v_week
                then v_week
            else p.last_freeze_week end,
        last_logged_week = v_week
    where p.id = v_user;

    if v_was_new and not p_stealth then
        insert into feed_events (user_id, event_type, movie_id, payload)
        select v_user, 'ranked', p_movie_id,
               jsonb_build_object('score', r.score, 'bucket', p_bucket)
        from rankings r where r.id = v_row.id;

        insert into notifications (recipient_id, actor_id, kind, movie_id)
        select w.user_id, v_user, 'friend_ranked_watchlist_movie', p_movie_id
        from watchlist w
        join follows f on f.follower_id = w.user_id and f.following_id = v_user
        where w.movie_id = p_movie_id;
    end if;

    if p_stealth then
        delete from feed_events
        where user_id = v_user and movie_id = p_movie_id and event_type = 'ranked';
    end if;

    if v_was_new then
        if not p_stealth then
            insert into notifications (recipient_id, actor_id, kind, movie_id)
            select dr.sender_id, v_user, 'rec_watched', p_movie_id
            from direct_recs dr
            where dr.recipient_id = v_user and dr.movie_id = p_movie_id
              and dr.sender_id <> v_user;
        end if;
        delete from direct_recs where recipient_id = v_user and movie_id = p_movie_id;
    end if;

    select * into v_row from rankings where id = v_row.id;
    return v_row;
end $$;

revoke execute on function public.rank_insert(integer, text, integer, date, boolean, text) from public, anon;
grant execute on function public.rank_insert(integer, text, integer, date, boolean, text) to authenticated;

-- ------------------------------------------------------------- notify_push

create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  -- Cron-paced and one-shot kinds: capping them starves exactly the users
  -- with the most activity (see 0123's rationale; the two retention kinds
  -- are at most 1/day and 1/week per user).
  v_exempt constant text[] := array['watchlist_showing', 'watch_invite',
                                    'watch_match', 'direct_rec',
                                    'post_watch_nudge', 'weekly_recap'];
begin
  if not (new.kind = any(v_exempt)) then
    if (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.id != new.id
          and not (n.kind = any(v_exempt))
          and n.created_at > now() - interval '1 hour') >= 5
    or (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.id != new.id
          and not (n.kind = any(v_exempt))
          and n.created_at > now() - interval '24 hours') >= 15
    then
      return new;
    end if;
  end if;
  perform net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/send-push',
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
exception when others then
  return new;
end $$;

-- -------------------------------------------------------- post-watch nudge

create or replace function public.send_post_watch_nudges()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_sent integer;
begin
    -- 72h lookback (was 36h): one failed cron run used to drop a whole band
    -- of plans permanently. The 7-day per-title dedupe and the not-ranked
    -- check below still make this at-most-once per person per title.
    with participants as (
        select wp.movie_id, m.user_id
        from watch_plans wp
        join watch_plan_members m on m.plan_id = wp.id and m.status = 'accepted'
        where wp.status = 'accepted'
          and wp.proposed_at between now() - interval '72 hours'
                                 and now() - interval '3 hours'
        union
        select wp.movie_id, wp.proposer_id
        from watch_plans wp
        where wp.status = 'accepted'
          and wp.proposed_at between now() - interval '72 hours'
                                 and now() - interval '3 hours'
    ), inserted as (
        insert into notifications (recipient_id, kind, movie_id)
        select distinct pt.user_id, 'post_watch_nudge', pt.movie_id
        from participants pt
        join profiles p on p.id = pt.user_id
        where not ('post_watch_nudge' = any(coalesce(p.muted_notification_kinds, '{}')))
          and not exists (select 1 from rankings r
                          where r.user_id = pt.user_id and r.movie_id = pt.movie_id)
          and not exists (select 1 from notifications n
                          where n.recipient_id = pt.user_id
                            and n.kind = 'post_watch_nudge'
                            and n.movie_id = pt.movie_id
                            and n.created_at > now() - interval '7 days')
        returning 1
    )
    select count(*) into v_sent from inserted;
    return v_sent;
end $$;

revoke all on function public.send_post_watch_nudges() from public, anon, authenticated;

-- ------------------------------------------------------------ weekly recap

create or replace function public.send_weekly_recaps()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_sent integer;
begin
    with inserted as (
        insert into notifications (recipient_id, kind, message)
        -- Every segment stands on its own: with no ranks of your own the
        -- message used to read as the fragment "friends ranked 12".
        select p.id, 'weekly_recap',
               concat_ws(' · ',
                   case when m.mine > 0
                        then 'You ranked ' || m.mine || ' title' || case when m.mine = 1 then '' else 's' end
                        end,
                   case when fr.friends > 0
                        then case when m.mine > 0 then 'friends ranked ' else 'Friends ranked ' end
                             || fr.friends || ' title' || case when fr.friends = 1 then '' else 's' end
                        end,
                   case when p.streak_weeks > 1
                        then p.streak_weeks || '-week streak 🔥' end)
        from profiles p
        cross join lateral (
            select count(*) as mine from rankings r
            where r.user_id = p.id and r.created_at > now() - interval '7 days') m
        cross join lateral (
            select count(*) as friends from feed_events e
            join follows f on f.following_id = e.user_id and f.follower_id = p.id
            where e.event_type = 'ranked'
              and e.created_at > now() - interval '7 days') fr
        where (m.mine > 0 or fr.friends > 0)
          and not ('weekly_recap' = any(coalesce(p.muted_notification_kinds, '{}')))
          and not exists (select 1 from notifications n
                          where n.recipient_id = p.id and n.kind = 'weekly_recap'
                            and n.created_at > now() - interval '6 days')
        returning 1
    )
    select count(*) into v_sent from inserted;
    return v_sent;
end $$;

revoke all on function public.send_weekly_recaps() from public, anon, authenticated;

-- ------------------------------------------------------------------ crews

create or replace function public.crew_create(p_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_crew uuid;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if char_length(trim(p_name)) not between 1 and 40 then
        raise exception 'bad name';
    end if;
    -- Serialize this user's crew-count check (two simultaneous creates could
    -- both read 4 and push them to 6).
    perform pg_advisory_xact_lock(hashtext(v_user::text || ':crews'));
    if (select count(*) from crew_members where user_id = v_user) >= 5 then
        raise exception 'crew limit';
    end if;
    insert into crews (name, owner_id) values (trim(p_name), v_user)
    returning id into v_crew;
    insert into crew_members (crew_id, user_id, added_by)
    values (v_crew, v_user, v_user);
    return v_crew;
end $$;

revoke all on function public.crew_create(text) from public, anon;
grant execute on function public.crew_create(text) to authenticated;

create or replace function public.crew_add_member(p_crew uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_name text;
    v_added integer;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if not exists (select 1 from crew_members
                   where crew_id = p_crew and user_id = v_user) then
        raise exception 'not a member';
    end if;
    if not exists (select 1 from follows a
                   join follows b on b.follower_id = a.following_id
                                 and b.following_id = a.follower_id
                   where a.follower_id = v_user and a.following_id = p_user) then
        raise exception 'not mutuals';
    end if;
    if exists (select 1 from blocks
               where (blocker_id = p_user and blocked_id = v_user)
                  or (blocker_id = v_user and blocked_id = p_user)) then
        raise exception 'blocked';
    end if;
    -- Serialize per crew AND per invitee so the 8-member and 5-crew caps
    -- can't be raced past (two members adding at the same moment both read
    -- the pre-insert count).
    perform pg_advisory_xact_lock(hashtext(p_crew::text || ':crew'));
    perform pg_advisory_xact_lock(hashtext(p_user::text || ':crews'));
    if (select count(*) from crew_members where crew_id = p_crew) >= 8 then
        raise exception 'crew full';
    end if;
    if (select count(*) from crew_members where user_id = p_user) >= 5 then
        raise exception 'crew limit';
    end if;

    insert into crew_members (crew_id, user_id, added_by)
    values (p_crew, p_user, v_user)
    on conflict (crew_id, user_id) do nothing;
    get diagnostics v_added = row_count;

    -- Only notify on a REAL add — re-adding an existing member used to fire
    -- another bell row and push every time.
    if v_added > 0 then
        select name into v_name from crews where id = p_crew;
        insert into notifications (recipient_id, actor_id, kind, message)
        select p_user, v_user, 'crew_added', v_name
        from profiles p
        where p.id = p_user
          and not ('crew_added' = any(coalesce(p.muted_notification_kinds, '{}')));
    end if;
end $$;

revoke all on function public.crew_add_member(uuid, uuid) from public, anon;
grant execute on function public.crew_add_member(uuid, uuid) to authenticated;
