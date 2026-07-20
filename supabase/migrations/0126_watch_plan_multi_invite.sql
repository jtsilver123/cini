-- Mirrors prod migration `watch_plan_multi_invite`.
--
-- Movie night for more than two: a watch plan becomes one host + a ROSTER
-- (watch_plan_members), so a user can invite several friends at once.
-- Semantics:
--   * each invitee accepts/declines individually (their member row);
--   * plan.status = 'accepted' once ANY invitee is in — the night is on;
--     it only turns 'declined' when EVERY invitee has passed;
--   * counter-proposing a time re-asks everyone (all member rows back to
--     'proposed', the suggester implicitly in), same as the pairwise flow;
--   * re-inviting for the same movie updates the host's live plan in place
--     (new time, roster additions) instead of stacking duplicates.
-- Existing pairwise plans backfill as a one-member roster; the old
-- propose_watch_plan(single) delegates to the new array version so older
-- app builds keep working unchanged.

-- 1) The roster.
create table if not exists public.watch_plan_members (
  plan_id uuid not null references public.watch_plans(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  status text not null default 'proposed'
    check (status in ('proposed', 'accepted', 'declined')),
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (plan_id, user_id)
);
create index if not exists watch_plan_members_user_idx
  on public.watch_plan_members (user_id);

alter table public.watch_plan_members enable row level security;

-- Participant test as SECURITY DEFINER so the members policy can consult
-- the members table itself without infinite RLS recursion.
create or replace function public.is_watch_plan_participant(p_plan uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from watch_plans
                 where id = p_plan and proposer_id = auth.uid())
      or exists (select 1 from watch_plan_members
                 where plan_id = p_plan and user_id = auth.uid());
$$;
revoke all on function public.is_watch_plan_participant(uuid) from public, anon;
grant execute on function public.is_watch_plan_participant(uuid) to authenticated;

drop policy if exists watch_plan_members_participant on public.watch_plan_members;
create policy watch_plan_members_participant on public.watch_plan_members
  for select using (public.is_watch_plan_participant(plan_id));

-- Roster members must see the plan row too (invitee_id alone no longer
-- covers everyone). Writes still only happen via SECURITY DEFINER RPCs.
drop policy if exists watch_plans_participant on public.watch_plans;
create policy watch_plans_participant on public.watch_plans
  using (public.is_watch_plan_participant(id) or auth.uid() = invitee_id);

-- 2) Backfill: every existing pairwise plan becomes a one-member roster.
insert into public.watch_plan_members (plan_id, user_id, status, created_at)
select id, invitee_id, status, created_at from public.watch_plans
on conflict (plan_id, user_id) do nothing;

-- 3) Propose to several friends at once.
create or replace function public.propose_watch_plan_multi(
  p_movie_id integer, p_invitees uuid[], p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_plan uuid;
  v_invitees uuid[];
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;

  -- De-dupe; drop self, unknown ids, and blocked pairs. An empty result
  -- is a graceful no-op, not an error (the contract check probes with a
  -- zero UUID, and a race-deleted profile shouldn't 500 the sheet).
  select array_agg(distinct u) into v_invitees
  from unnest(coalesce(p_invitees, '{}')) u
  where u <> auth.uid()
    and exists (select 1 from profiles where id = u)
    and not_blocked_pair(auth.uid(), u);
  if v_invitees is null then return null; end if;
  if array_length(v_invitees, 1) > 10 then
    raise exception 'too many invitees';
  end if;

  -- One live plan per (movie, host): re-proposing updates it in place.
  select id into v_plan from watch_plans
   where movie_id = p_movie_id and proposer_id = auth.uid()
     and status in ('proposed', 'accepted')
   order by created_at desc limit 1;

  if v_plan is not null then
    update watch_plans
       set proposed_at = p_proposed_at, status = 'proposed',
           last_proposer = auth.uid()
     where id = v_plan;
    -- Everyone re-confirms the (possibly new) time.
    update watch_plan_members set status = 'proposed', responded_at = null
     where plan_id = v_plan;
  else
    insert into watch_plans (movie_id, proposer_id, invitee_id, proposed_at, last_proposer)
    values (p_movie_id, auth.uid(), v_invitees[1], p_proposed_at, auth.uid())
    returning id into v_plan;
  end if;

  insert into watch_plan_members (plan_id, user_id)
  select v_plan, u from unnest(v_invitees) u
  on conflict (plan_id, user_id) do update
    set status = 'proposed', responded_at = null;

  -- watch_invite is a must-deliver push kind (0123) — every invitee hears.
  insert into notifications (recipient_id, actor_id, kind, movie_id)
  select u, auth.uid(), 'watch_invite', p_movie_id from unnest(v_invitees) u;

  return v_plan;
end $$;
revoke all on function public.propose_watch_plan_multi(integer, uuid[], timestamptz) from public, anon;
grant execute on function public.propose_watch_plan_multi(integer, uuid[], timestamptz) to authenticated;

-- Single-friend path (older builds, watch-match push) rides the same code.
create or replace function public.propose_watch_plan(
  p_movie_id integer, p_invitee uuid, p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
begin
  return propose_watch_plan_multi(p_movie_id, array[p_invitee], p_proposed_at);
end $$;
revoke all on function public.propose_watch_plan(integer, uuid, timestamptz) from public, anon;
grant execute on function public.propose_watch_plan(integer, uuid, timestamptz) to authenticated;

-- 4) Respond, roster-aware.
create or replace function public.respond_watch_plan(
  p_plan_id uuid, p_accept boolean, p_new_time timestamptz default null)
returns void
language plpgsql security definer set search_path = public as $$
declare
  pl record;
  v_is_member boolean;
  v_notify uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  select * into pl from watch_plans where id = p_plan_id;
  if pl is null then raise exception 'no such plan'; end if;
  v_is_member := exists (select 1 from watch_plan_members
                         where plan_id = p_plan_id and user_id = auth.uid());
  if auth.uid() <> pl.proposer_id and not v_is_member then
    raise exception 'not a participant';
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
    -- One yes = the night is ON (stragglers can still join or pass).
    update watch_plans set status = 'accepted' where id = p_plan_id;
    -- Tell whoever suggested the current time (fall back to the host,
    -- then to any other member) — never notify yourself.
    v_notify := coalesce(pl.last_proposer, pl.proposer_id);
    if v_notify = auth.uid() then v_notify := pl.proposer_id; end if;
    if v_notify = auth.uid() then
      select user_id into v_notify from watch_plan_members
       where plan_id = p_plan_id and user_id <> auth.uid()
       order by created_at limit 1;
    end if;
    if v_notify is not null and v_notify <> auth.uid() then
      insert into notifications (recipient_id, actor_id, kind, movie_id)
      values (v_notify, auth.uid(), 'watch_invite', pl.movie_id);
    end if;
  else
    if v_is_member then
      update watch_plan_members set status = 'declined', responded_at = now()
       where plan_id = p_plan_id and user_id = auth.uid();
    end if;
    -- The night dies only when EVERYONE has passed.
    if not exists (select 1 from watch_plan_members
                   where plan_id = p_plan_id and status <> 'declined') then
      update watch_plans set status = 'declined' where id = p_plan_id;
    end if;
  end if;
end $$;
revoke all on function public.respond_watch_plan(uuid, boolean, timestamptz) from public, anon;
grant execute on function public.respond_watch_plan(uuid, boolean, timestamptz) to authenticated;
