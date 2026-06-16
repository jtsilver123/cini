-- 0065_watch_match.sql
-- "Watch Match": when two mutual-follow friends both have a title on their Want
-- to Watch (and neither has ranked it), nudge both to plan to watch it TOGETHER
-- — pick a time, the friend accepts or proposes another. Tables, RLS, the
-- nightly detector, the plan RPCs, and the new notification kinds.

-- A block-aware helper: neither user has blocked the other.
create or replace function public.not_blocked_pair(a uuid, b uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from blocks
    where (blocker_id = a and blocked_id = b)
       or (blocker_id = b and blocked_id = a)
  );
$$;

-- ---- Detected overlaps (canonical pair: user_low < user_high) ----
create table if not exists public.watch_matches (
  id         uuid primary key default gen_random_uuid(),
  movie_id   integer not null references public.movies(tmdb_id),
  user_low   uuid not null references public.profiles(id) on delete cascade,
  user_high  uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  unique (movie_id, user_low, user_high)
);
create index watch_matches_users_idx on public.watch_matches (user_low, user_high);
alter table public.watch_matches enable row level security;
create policy watch_matches_participant on public.watch_matches
  for select to authenticated
  using (auth.uid() = user_low or auth.uid() = user_high);

-- ---- A proposed watch-together plan (proposed_at = the "when is good" time) ----
create table if not exists public.watch_plans (
  id          uuid primary key default gen_random_uuid(),
  movie_id    integer not null references public.movies(tmdb_id),
  proposer_id uuid not null references public.profiles(id) on delete cascade,
  invitee_id  uuid not null references public.profiles(id) on delete cascade,
  proposed_at timestamptz,
  status      text not null default 'proposed'
              check (status in ('proposed','accepted','declined')),
  created_at  timestamptz not null default now()
);
create index watch_plans_people_idx on public.watch_plans (invitee_id, proposer_id, created_at desc);
alter table public.watch_plans enable row level security;
create policy watch_plans_participant on public.watch_plans
  for select to authenticated
  using (auth.uid() = proposer_id or auth.uid() = invitee_id);
-- Writes go through the RPCs below (security definer); no direct client writes.

-- ---- Notification kinds ----
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind = any (array[
    'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
    'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
    'rate_nudge','friend_loved','follow_request','follow_request_approved',
    'saved_your_rank','streak_reminder','tonight_pick','watch_match','watch_invite']));

-- ---- Nightly detector (service-role; called by cron) ----
-- New overlaps among mutual-follow, non-blocked friends who both want a title
-- neither has ranked. Inserts a watch_matches row (unique → once per pair+movie)
-- and notifies BOTH users (actor = the other person).
create or replace function public.detect_watch_matches()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  m record;
  inserted integer := 0;
begin
  for m in
    select wa.movie_id,
           least(wa.user_id, wb.user_id)    as user_low,
           greatest(wa.user_id, wb.user_id) as user_high
    from watchlist wa
    join watchlist wb
      on wb.movie_id = wa.movie_id and wb.user_id > wa.user_id
    -- mutual follow both ways
    join follows f1 on f1.follower_id = wa.user_id and f1.following_id = wb.user_id
    join follows f2 on f2.follower_id = wb.user_id and f2.following_id = wa.user_id
    where not_blocked_pair(wa.user_id, wb.user_id)
      and not exists (select 1 from rankings r
                      where r.movie_id = wa.movie_id and r.user_id in (wa.user_id, wb.user_id))
      and not exists (select 1 from watch_matches wm
                      where wm.movie_id = wa.movie_id
                        and wm.user_low = least(wa.user_id, wb.user_id)
                        and wm.user_high = greatest(wa.user_id, wb.user_id))
  loop
    insert into watch_matches (movie_id, user_low, user_high)
    values (m.movie_id, m.user_low, m.user_high)
    on conflict do nothing;

    insert into notifications (recipient_id, actor_id, kind, movie_id)
    values (m.user_low,  m.user_high, 'watch_match', m.movie_id),
           (m.user_high, m.user_low,  'watch_match', m.movie_id);
    inserted := inserted + 1;
  end loop;
  return inserted;
end $$;
revoke all on function public.detect_watch_matches() from public, anon, authenticated;

-- ---- Propose a watch-together plan (the in-app sheet → here) ----
create or replace function public.propose_watch_plan(
  p_movie_id integer, p_invitee uuid, p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not not_blocked_pair(auth.uid(), p_invitee) then raise exception 'blocked'; end if;

  insert into watch_plans (movie_id, proposer_id, invitee_id, proposed_at)
  values (p_movie_id, auth.uid(), p_invitee, p_proposed_at)
  returning id into new_id;

  insert into notifications (recipient_id, actor_id, kind, movie_id)
  values (p_invitee, auth.uid(), 'watch_invite', p_movie_id);

  return new_id;
end $$;
revoke all on function public.propose_watch_plan(integer, uuid, timestamptz) from public, anon;
grant execute on function public.propose_watch_plan(integer, uuid, timestamptz) to authenticated;

-- ---- Respond to a plan (accept / decline / propose a new time) ----
create or replace function public.respond_watch_plan(
  p_plan_id uuid, p_accept boolean, p_new_time timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare pl record;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into pl from watch_plans where id = p_plan_id;
  if pl is null then raise exception 'no such plan'; end if;
  if auth.uid() <> pl.invitee_id and auth.uid() <> pl.proposer_id then
    raise exception 'not a participant';
  end if;

  if p_new_time is not null then
    update watch_plans set proposed_at = p_new_time, status = 'proposed' where id = p_plan_id;
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    values (case when auth.uid() = pl.invitee_id then pl.proposer_id else pl.invitee_id end,
            auth.uid(), 'watch_invite', pl.movie_id);
  else
    update watch_plans set status = case when p_accept then 'accepted' else 'declined' end
    where id = p_plan_id;
    if p_accept then
      insert into notifications (recipient_id, actor_id, kind, movie_id)
      values (pl.proposer_id, auth.uid(), 'watch_invite', pl.movie_id);
    end if;
  end if;
end $$;
revoke all on function public.respond_watch_plan(uuid, boolean, timestamptz) from public, anon;
grant execute on function public.respond_watch_plan(uuid, boolean, timestamptz) to authenticated;
