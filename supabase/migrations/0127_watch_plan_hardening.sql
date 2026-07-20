-- Mirrors prod migration `watch_plan_hardening`.
--
-- Fixes every confirmed server-side finding from the multi-invite audit:
--
--  1. CRITICAL: 0126 recreated the watch_plans policy without `for select`,
--     silently making it FOR ALL — participants could PATCH/DELETE plans
--     directly and anyone could forge a plan naming a victim as host.
--     Back to SELECT-only; writes go through the RPCs, as documented.
--  2. Plan reuse is now scoped to the SAME GROUP: re-proposing only reuses
--     a hosted live plan whose roster overlaps the new invitees. Inviting a
--     disjoint friend creates a SEPARATE plan — it no longer nukes an
--     already-accepted night with someone else, retimes it, or leaks
--     co-invitee identities across unrelated 1:1 invites.
--  3. Reuse with an UNCHANGED time keeps everyone's RSVPs (only re-asks
--     previously-declined targets); a changed time re-asks the whole
--     roster AND notifies the whole roster (not just this call's names).
--     Repeat no-op calls notify nobody — kills the uncapped push-spam
--     loop (watch_invite is cap-exempt, so dedupe must happen here).
--  4. The 10-friend cap now applies to the POST-upsert roster, not just
--     one call's array.
--  5. Mutual-invite race: proposing to people who are ALL already on a
--     live plan I'm part of counter-proposes on THAT plan instead of
--     forking a contradictory duplicate.
--  6. Blocked invitees raise 'blocked' again (0065 semantics); only
--     unknown ids/self are silently dropped (the contract probe's zero
--     UUID stays a graceful no-op).
--  7. The host can actually cancel: their "Can't make it" declines the
--     plan (it was a silent no-op — the host has no member row).
--  8. respond_watch_plan locks the plan row (FOR UPDATE) — two invitees
--     declining simultaneously could each miss the other and strand the
--     plan live forever.
--  9. Accepts carry an optional p_expected_time guard: accepting a time
--     that changed under you raises 'time changed' instead of confirming
--     a night you never saw.
-- 10. Accepting notifies BOTH the host and whoever suggested the current
--     time, as a new 'watch_accept' kind ("X is in") — an acceptance no
--     longer masquerades as a fresh invite. watch_accept joins the
--     must-deliver push exemption.
-- 11. Host accepting a counter-proposed time also credits the suggester's
--     member row as accepted (the plan can no longer be 'accepted' with
--     zero accepted members).
-- 12. Backfill correction: pairwise plans that were mid counter-propose
--     get the suggester's member row marked accepted.
-- 13. Blocking now severs watch plans across the pair (member rows pulled
--     both ways; a hosted plan left with an empty roster is declined).
-- 14. user_locations gains alert_radius + set_home_area RPC so the ticket
--     alert sweep can honor the radius the user actually picked (it was
--     hardcoded to 15 mi server-side while the UI promised 5-50).
-- 15. set_notification_kind_muted flips ONE kind atomically — the client
--     read-modify-write raced Settings and clobbered other mutes.

-- ---- 1. SELECT-only policy again ----
drop policy if exists watch_plans_participant on public.watch_plans;
create policy watch_plans_participant on public.watch_plans
  for select to authenticated
  using (public.is_watch_plan_participant(id) or auth.uid() = invitee_id);

-- ---- 10a. watch_accept kind ----
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (
    kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved','saved_your_rank',
        'streak_reminder','tonight_pick','watch_match','watch_invite','contact_joined',
        'friend_watching','caught_up','mention','rec_passed','rec_watched','watch_accept'
    ])
);

create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_exempt constant text[] := array['watchlist_showing', 'watch_invite',
                                    'watch_match', 'direct_rec', 'watch_accept'];
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

-- ---- 12. Backfill: mid-counter-propose suggesters are IN ----
update public.watch_plan_members m set status = 'accepted'
from public.watch_plans p
where m.plan_id = p.id and p.status = 'proposed'
  and p.last_proposer = m.user_id and m.status = 'proposed';

-- ---- 13. Blocking severs plans across the pair ----
create or replace function public.sever_on_block()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    delete from follows
    where (follower_id = new.blocker_id and following_id = new.blocked_id)
       or (follower_id = new.blocked_id and following_id = new.blocker_id);
    delete from follow_requests
    where (requester_id = new.blocker_id and target_id = new.blocked_id)
       or (requester_id = new.blocked_id and target_id = new.blocker_id);
    -- Pull the pair off each other's watch plans: each leaves any plan the
    -- other hosts. A hosted plan left with an empty roster is dead.
    delete from watch_plan_members m
    using watch_plans p
    where m.plan_id = p.id
      and ((p.proposer_id = new.blocker_id and m.user_id = new.blocked_id)
        or (p.proposer_id = new.blocked_id and m.user_id = new.blocker_id));
    update watch_plans p set status = 'declined'
    where p.status <> 'declined'
      and p.proposer_id in (new.blocker_id, new.blocked_id)
      and not exists (select 1 from watch_plan_members m where m.plan_id = p.id);
    return new;
end $$;

-- ---- 14. Persisted alert radius ----
alter table public.user_locations
  add column if not exists alert_radius integer not null default 15;

create or replace function public.set_home_area(p_zip text, p_radius integer default null)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is null then raise exception 'not authenticated'; end if;
    if p_zip is not null and p_zip !~ '^[0-9]{5}$' then
        raise exception 'invalid zip';
    end if;
    if p_radius is not null and p_radius not in (5, 10, 15, 25, 50) then
        raise exception 'invalid radius';
    end if;
    insert into public.user_locations (user_id, home_zip, alert_radius)
    values (auth.uid(), p_zip, coalesce(p_radius, 15))
    on conflict (user_id) do update
      set home_zip = excluded.home_zip,
          alert_radius = coalesce(p_radius, user_locations.alert_radius),
          updated_at = now();
end $$;
revoke all on function public.set_home_area(text, integer) from public, anon;
grant execute on function public.set_home_area(text, integer) to authenticated;

-- ---- 15. Atomic per-kind mute flip ----
create or replace function public.set_notification_kind_muted(p_kind text, p_muted boolean)
returns void
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is null then raise exception 'not authenticated'; end if;
    if p_kind is null or length(p_kind) > 64 then raise exception 'bad kind'; end if;
    update profiles
       set muted_notification_kinds = case when p_muted
             then (select array_agg(distinct k)
                   from unnest(array_append(muted_notification_kinds, p_kind)) k)
             else array_remove(muted_notification_kinds, p_kind) end
     where id = auth.uid();
end $$;
revoke all on function public.set_notification_kind_muted(text, boolean) from public, anon;
grant execute on function public.set_notification_kind_muted(text, boolean) to authenticated;

-- ---- 2-6. propose_watch_plan_multi v2 ----
create or replace function public.propose_watch_plan_multi(
  p_movie_id integer, p_invitees uuid[], p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plan uuid;
  v_invitees uuid[];
  v_new_members uuid[];
  v_reasked uuid[];
  v_time_changed boolean;
  v_roster integer;
  pl record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  -- A blocked target is an ERROR (0065 semantics) — never silently spoofed
  -- around. Unknown ids and self are dropped quietly (the contract probe
  -- uses a zero UUID and a race-deleted profile shouldn't 500 the sheet).
  if exists (select 1 from unnest(coalesce(p_invitees, '{}')) u
             where u <> auth.uid()
               and exists (select 1 from profiles where id = u)
               and not not_blocked_pair(auth.uid(), u)) then
    raise exception 'blocked';
  end if;
  select array_agg(distinct u) into v_invitees
  from unnest(coalesce(p_invitees, '{}')) u
  where u <> auth.uid()
    and exists (select 1 from profiles where id = u);
  if v_invitees is null then return null; end if;
  if array_length(v_invitees, 1) > 10 then
    raise exception 'too many invitees';
  end if;

  -- Reuse MY hosted live plan only when its roster OVERLAPS the new
  -- invitees — that's a re-propose to the same group. A disjoint set is a
  -- different movie night and gets its own plan.
  select p.id into v_plan from watch_plans p
   where p.movie_id = p_movie_id and p.proposer_id = auth.uid()
     and p.status in ('proposed', 'accepted')
     and exists (select 1 from watch_plan_members m
                 where m.plan_id = p.id and m.user_id = any(v_invitees))
   order by p.created_at desc limit 1
   for update;

  if v_plan is null then
    -- Mutual-invite race / inviting the host back: if a live plan I'm on
    -- already covers every target, counter-propose THERE instead of
    -- forking a contradictory duplicate.
    select p.id into v_plan from watch_plans p
     where p.movie_id = p_movie_id and p.status in ('proposed', 'accepted')
       and public.is_watch_plan_participant(p.id)
       and not exists (select 1 from unnest(v_invitees) u
                       where u <> p.proposer_id
                         and not exists (select 1 from watch_plan_members m
                                         where m.plan_id = p.id and m.user_id = u))
     order by p.created_at desc limit 1
     for update;
    if v_plan is not null then
      perform public.respond_watch_plan(v_plan, true, p_proposed_at);
      return v_plan;
    end if;
  end if;

  if v_plan is not null then
    select * into pl from watch_plans where id = v_plan;
    v_time_changed := pl.proposed_at is distinct from p_proposed_at;

    -- The cap covers the whole roster after this call, not just one array.
    select count(*) into v_roster from (
      select user_id from watch_plan_members where plan_id = v_plan
      union select u from unnest(v_invitees) u) r;
    if v_roster > 10 then raise exception 'too many invitees'; end if;

    select coalesce(array_agg(u), '{}') into v_new_members
    from unnest(v_invitees) u
    where not exists (select 1 from watch_plan_members m
                      where m.plan_id = v_plan and m.user_id = u);
    select coalesce(array_agg(user_id), '{}') into v_reasked
    from watch_plan_members
    where plan_id = v_plan and user_id = any(v_invitees) and status = 'declined';

    if v_time_changed then
      update watch_plans
         set proposed_at = p_proposed_at, status = 'proposed',
             last_proposer = auth.uid()
       where id = v_plan;
      update watch_plan_members set status = 'proposed', responded_at = null
       where plan_id = v_plan;
    else
      -- Same time: existing RSVPs stand; only re-ask the declined targets.
      update watch_plan_members set status = 'proposed', responded_at = null
       where plan_id = v_plan and user_id = any(v_reasked);
    end if;

    insert into watch_plan_members (plan_id, user_id)
    select v_plan, u from unnest(v_new_members) u
    on conflict (plan_id, user_id) do nothing;

    -- A time change re-invites the WHOLE roster (they all must re-confirm);
    -- otherwise only genuinely new or re-asked people hear. A repeat no-op
    -- call notifies nobody — watch_invite is cap-exempt, so the dedupe
    -- lives here.
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    select m.user_id, auth.uid(), 'watch_invite', p_movie_id
    from watch_plan_members m
    where m.plan_id = v_plan and m.user_id <> auth.uid()
      and (v_time_changed
           or m.user_id = any(v_new_members)
           or m.user_id = any(v_reasked));
  else
    insert into watch_plans (movie_id, proposer_id, invitee_id, proposed_at, last_proposer)
    values (p_movie_id, auth.uid(), v_invitees[1], p_proposed_at, auth.uid())
    returning id into v_plan;

    insert into watch_plan_members (plan_id, user_id)
    select v_plan, u from unnest(v_invitees) u;

    insert into notifications (recipient_id, actor_id, kind, movie_id)
    select u, auth.uid(), 'watch_invite', p_movie_id from unnest(v_invitees) u;
  end if;

  return v_plan;
end $$;
revoke all on function public.propose_watch_plan_multi(integer, uuid[], timestamptz) from public, anon;
grant execute on function public.propose_watch_plan_multi(integer, uuid[], timestamptz) to authenticated;

-- ---- 7-11. respond_watch_plan v3 ----
-- Signature gains p_expected_time; drop the old 3-arg overload so PostgREST
-- resolution stays unambiguous (old builds' 3-arg named calls bind fine).
drop function if exists public.respond_watch_plan(uuid, boolean, timestamptz);
create or replace function public.respond_watch_plan(
  p_plan_id uuid, p_accept boolean, p_new_time timestamptz default null,
  p_expected_time timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  v_is_member boolean;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  -- Lock the plan: simultaneous responders must serialize, or two "can't
  -- make it"s can each miss the other and strand the plan live forever.
  select * into pl from watch_plans where id = p_plan_id for update;
  if pl is null then raise exception 'no such plan'; end if;
  v_is_member := exists (select 1 from watch_plan_members
                         where plan_id = p_plan_id and user_id = auth.uid());
  if auth.uid() <> pl.proposer_id and not v_is_member then
    raise exception 'not a participant';
  end if;

  -- Respond to the time you actually SAW: if it changed underneath you,
  -- bail so the client can re-show the new time instead of confirming a
  -- night the user never agreed to. (Old builds omit the param — no check.)
  if p_expected_time is not null
     and pl.proposed_at is distinct from p_expected_time then
    raise exception 'time changed';
  end if;

  if p_new_time is not null then
    -- Counter-propose: everyone re-confirms; the suggester is implicitly in.
    update watch_plans set proposed_at = p_new_time, status = 'proposed',
                           last_proposer = auth.uid()
    where id = p_plan_id;
    update watch_plan_members set status = 'proposed', responded_at = null
     where plan_id = p_plan_id and user_id <> auth.uid();
    if v_is_member then
      update watch_plan_members set status = 'accepted', responded_at = now()
       where plan_id = p_plan_id and user_id = auth.uid();
    end if;
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    select parts.u, auth.uid(), 'watch_invite', pl.movie_id
    from (select user_id as u from watch_plan_members where plan_id = p_plan_id
          union select pl.proposer_id) parts
    where parts.u <> auth.uid();
  elsif p_accept then
    if v_is_member then
      update watch_plan_members set status = 'accepted', responded_at = now()
       where plan_id = p_plan_id and user_id = auth.uid();
    end if;
    -- The host accepting a counter-proposed time also seals the suggester
    -- in — otherwise the plan could sit 'accepted' with zero accepted rows.
    if auth.uid() = pl.proposer_id and pl.last_proposer is not null
       and pl.last_proposer <> pl.proposer_id then
      update watch_plan_members set status = 'accepted', responded_at = now()
       where plan_id = p_plan_id and user_id = pl.last_proposer
         and status <> 'declined';
    end if;
    -- One yes = the night is ON (stragglers can still join or pass).
    update watch_plans set status = 'accepted' where id = p_plan_id;
    -- "X is in" reaches the host AND whoever suggested the current time.
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    select t.u, auth.uid(), 'watch_accept', pl.movie_id
    from (select pl.proposer_id as u
          union select coalesce(pl.last_proposer, pl.proposer_id)) t
    where t.u <> auth.uid();
  else
    if v_is_member then
      update watch_plan_members set status = 'declined', responded_at = now()
       where plan_id = p_plan_id and user_id = auth.uid();
    end if;
    if auth.uid() = pl.proposer_id then
      -- The HOST can't make it: the night is off. (This was a silent
      -- no-op — the host has no member row.)
      update watch_plans set status = 'declined' where id = p_plan_id;
    elsif not exists (select 1 from watch_plan_members
                      where plan_id = p_plan_id and status <> 'declined') then
      -- The night dies only when EVERY invitee has passed.
      update watch_plans set status = 'declined' where id = p_plan_id;
    end if;
  end if;
end $$;
revoke all on function public.respond_watch_plan(uuid, boolean, timestamptz, timestamptz) from public, anon;
grant execute on function public.respond_watch_plan(uuid, boolean, timestamptz, timestamptz) to authenticated;
