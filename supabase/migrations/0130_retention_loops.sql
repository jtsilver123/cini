-- Retention loops, part 1 (mirrors prod migration `retention_loops`):
--
-- 1) STREAK FREEZES — Duolingo's most effective retention mechanic, adapted
--    to weekly cadence. Rank 3+ titles in one week → earn a freeze (max 2
--    banked). Miss exactly one week with a freeze banked → the freeze is
--    consumed and the streak SURVIVES (the missed week doesn't add, the new
--    week does). Implemented inside rank_insert, the sole writer of both
--    rankings and the streak columns.
--
-- 2) POST-WATCH RANK NUDGE — the habit anchor. The morning after an accepted
--    watch plan's time passes, everyone on the plan (proposer + accepted
--    members) who hasn't ranked the title gets one 'post_watch_nudge'
--    notification ("How was X? Rank it"). Ranking right after watching is
--    the core habit; this is the one moment the app KNOWS a watch happened.
--    Daily cron at 14:00 UTC (morning in the US).
--
-- 3) WEEKLY RECAP — a Sunday-evening 'weekly_recap' notification with the
--    user's week in one line (ranked count · friends' ranked count · streak).
--    Weekly matches how people actually watch; an achievable ritual beats an
--    ignorable daily ping. Cron Sundays 22:00 UTC (~5-6pm ET).
--
-- 4) WATCH OVERLAPS RPC — powers the feed's "you and @sam both want to
--    watch X" card (the passive-save → social-plan converter). Returns the
--    caller's Want to Watch titles that mutual friends also saved.
--
-- All notification inserts respect profiles.muted_notification_kinds and
-- dedupe against re-runs. New kinds added to the check constraint
-- ('crew_added' ships with 0131 but is registered here alongside).

-- ---------------------------------------------------------------- freezes

alter table public.profiles
  add column if not exists streak_freezes integer not null default 0;

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (
    kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved','saved_your_rank',
        'streak_reminder','tonight_pick','watch_match','watch_invite','contact_joined',
        'friend_watching','caught_up','mention','rec_passed','rec_watched','watch_accept',
        'post_watch_nudge','weekly_recap','crew_added'
    ])
);

-- rank_insert: identical to 0110 except the streak block, which now earns
-- and consumes freezes. Signature unchanged.
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

    -- Only trust a real IANA zone; otherwise UTC. The week is the user's local
    -- week so "ranked this week" matches their calendar, not the server's.
    v_tz := coalesce((select name from pg_timezone_names where name = p_tz limit 1), 'UTC');
    v_week := date_trunc('week', now() at time zone v_tz)::date;

    select media_kind into v_kind from movies where tmdb_id = p_movie_id;
    if v_kind is null then raise exception 'unknown movie %', p_movie_id; end if;

    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    -- Re-ranking: pull the old row out and close its gap (same kind).
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

    insert into rankings (user_id, movie_id, bucket, position, score, watch_date, watched_with)
    values (v_user, p_movie_id, p_bucket, v_pos, 0,
            coalesce(p_watch_date, v_old.watch_date),
            coalesce(v_old.watched_with, '{}'))
    returning * into v_row;

    perform rescore_bucket(v_user, p_bucket, v_kind);

    delete from watchlist where user_id = v_user and movie_id = p_movie_id;

    -- How many ranks landed in the user's current local week (including this
    -- one) — the 3rd earns a streak freeze, exactly once per week.
    select count(*) into v_week_ranks
    from rankings r
    where r.user_id = v_user
      and (r.created_at at time zone v_tz)::date >= v_week;

    update profiles p set
        streak_weeks = case
            when p.last_logged_week = v_week then p.streak_weeks
            when p.last_logged_week = v_week - 7 then p.streak_weeks + 1
            -- Missed exactly one week with a freeze banked: the freeze covers
            -- the gap — streak survives (missed week adds nothing, this week
            -- adds one).
            when p.last_logged_week = v_week - 14
                 and coalesce(p.streak_freezes, 0) > 0 then p.streak_weeks + 1
            else 1 end,
        streak_freezes = greatest(0, least(2, case
            when p.last_logged_week = v_week - 14
                 and coalesce(p.streak_freezes, 0) > 0 then coalesce(p.streak_freezes, 0) - 1
            when v_week_ranks = 3 then coalesce(p.streak_freezes, 0) + 1
            else coalesce(p.streak_freezes, 0) end)),
        last_logged_week = v_week
    where p.id = v_user;

    -- Public ranks announce themselves; stealth ranks never do.
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

    -- A re-rank into stealth (or a stealth rank racing an older event) must
    -- leave nothing public behind.
    if p_stealth then
        delete from feed_events
        where user_id = v_user and movie_id = p_movie_id and event_type = 'ranked';
    end if;

    -- Resolve any direct recs of this title sent TO you: clear them from your
    -- Friend Recs, and — unless this is a stealth rank (which stays hidden from
    -- friends) — tell each sender you watched what they recommended.
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

-- ------------------------------------------------- post-watch rank nudge

create or replace function public.send_post_watch_nudges()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_sent integer;
begin
    -- Participants = the proposer plus every accepted roster member (the
    -- proposer is NOT in watch_plan_members). Window: plans whose time
    -- passed 3-36 hours ago — "the morning after", caught exactly once by
    -- the daily run (with a 7-day per-title dedupe as a belt-and-braces
    -- guard against re-runs and rescheduled plans).
    with participants as (
        select wp.movie_id, m.user_id
        from watch_plans wp
        join watch_plan_members m on m.plan_id = wp.id and m.status = 'accepted'
        where wp.status = 'accepted'
          and wp.proposed_at between now() - interval '36 hours'
                                 and now() - interval '3 hours'
        union
        select wp.movie_id, wp.proposer_id
        from watch_plans wp
        where wp.status = 'accepted'
          and wp.proposed_at between now() - interval '36 hours'
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

select cron.schedule('post-watch-nudges-daily', '0 14 * * *',
                     'select public.send_post_watch_nudges()');

-- --------------------------------------------------------- weekly recap

create or replace function public.send_weekly_recaps()
returns integer
language plpgsql security definer set search_path = public as $$
declare
    v_sent integer;
begin
    with inserted as (
        insert into notifications (recipient_id, kind, message)
        select p.id, 'weekly_recap',
               concat_ws(' · ',
                   case when m.mine > 0
                        then 'You ranked ' || m.mine || ' title' || case when m.mine = 1 then '' else 's' end
                        end,
                   case when fr.friends > 0
                        then 'friends ranked ' || fr.friends end,
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
          -- once per week even if the cron re-runs
          and not exists (select 1 from notifications n
                          where n.recipient_id = p.id and n.kind = 'weekly_recap'
                            and n.created_at > now() - interval '6 days')
        returning 1
    )
    select count(*) into v_sent from inserted;
    return v_sent;
end $$;

revoke all on function public.send_weekly_recaps() from public, anon, authenticated;

select cron.schedule('weekly-recap-sunday', '0 22 * * 0',
                     'select public.send_weekly_recaps()');

-- ------------------------------------------------------- watch overlaps

-- Titles on MY Want to Watch that mutual friends also want — newest of my
-- saves first, with the friends who share each one. Powers the feed's
-- "plan it together" card.
create or replace function public.watch_overlaps(p_limit integer default 5)
returns table (
    movie_id integer,
    friend_ids uuid[],
    friend_usernames text[]
)
language sql security definer set search_path = public
stable as $$
    select w.movie_id,
           array_agg(f.following_id order by fw.created_at) as friend_ids,
           array_agg(pr.username order by fw.created_at) as friend_usernames
    from watchlist w
    join follows f on f.follower_id = auth.uid()
    join follows fb on fb.follower_id = f.following_id and fb.following_id = auth.uid()
    join watchlist fw on fw.user_id = f.following_id and fw.movie_id = w.movie_id
    join profiles pr on pr.id = f.following_id
    where w.user_id = auth.uid()
      and not exists (select 1 from blocks b
                      where (b.blocker_id = auth.uid() and b.blocked_id = f.following_id)
                         or (b.blocker_id = f.following_id and b.blocked_id = auth.uid()))
    group by w.movie_id, w.created_at
    order by w.created_at desc
    limit greatest(1, least(p_limit, 20));
$$;

revoke all on function public.watch_overlaps(integer) from public, anon;
grant execute on function public.watch_overlaps(integer) to authenticated;
