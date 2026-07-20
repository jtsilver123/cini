-- Mirrors prod migration `watch_plan_last_proposer`.
--
-- Counter-proposing a watch-plan time deadlocked the plan: the row kept the
-- ORIGINAL proposer_id, so after "suggest a different time" both sides saw
-- the waiting/respond UI for the wrong person and nobody had an Accept
-- button. Track WHO suggested the current time (last_proposer) and drive the
-- respond/waiting split off that. Also:
--   * propose_watch_plan reuses the live plan for the (movie, pair) instead
--     of stacking a duplicate row that could shadow an accepted plan;
--   * the accept notification goes to the OTHER participant (it went to
--     proposer_id even when the proposer was the one accepting a
--     counter-proposed time — notifying themselves).

alter table public.watch_plans
  add column if not exists last_proposer uuid references public.profiles(id) on delete set null;
update public.watch_plans set last_proposer = proposer_id where last_proposer is null;

create or replace function public.propose_watch_plan(
  p_movie_id integer, p_invitee uuid, p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if not not_blocked_pair(auth.uid(), p_invitee) then raise exception 'blocked'; end if;

  -- One live plan per (movie, pair): re-proposing updates it in place.
  select id into new_id from watch_plans
   where movie_id = p_movie_id
     and status in ('proposed', 'accepted')
     and ((proposer_id = auth.uid() and invitee_id = p_invitee)
       or (proposer_id = p_invitee and invitee_id = auth.uid()))
   order by created_at desc limit 1;

  if new_id is not null then
    update watch_plans
       set proposed_at = p_proposed_at, status = 'proposed',
           last_proposer = auth.uid()
     where id = new_id;
  else
    insert into watch_plans (movie_id, proposer_id, invitee_id, proposed_at, last_proposer)
    values (p_movie_id, auth.uid(), p_invitee, p_proposed_at, auth.uid())
    returning id into new_id;
  end if;

  insert into notifications (recipient_id, actor_id, kind, movie_id)
  values (p_invitee, auth.uid(), 'watch_invite', p_movie_id);

  return new_id;
end $$;
revoke all on function public.propose_watch_plan(integer, uuid, timestamptz) from public, anon;
grant execute on function public.propose_watch_plan(integer, uuid, timestamptz) to authenticated;

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
    update watch_plans set proposed_at = p_new_time, status = 'proposed',
                           last_proposer = auth.uid()
    where id = p_plan_id;
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    values (case when auth.uid() = pl.invitee_id then pl.proposer_id else pl.invitee_id end,
            auth.uid(), 'watch_invite', pl.movie_id);
  else
    update watch_plans set status = case when p_accept then 'accepted' else 'declined' end
    where id = p_plan_id;
    if p_accept then
      insert into notifications (recipient_id, actor_id, kind, movie_id)
      values (case when auth.uid() = pl.proposer_id then pl.invitee_id else pl.proposer_id end,
              auth.uid(), 'watch_invite', pl.movie_id);
    end if;
  end if;
end $$;
revoke all on function public.respond_watch_plan(uuid, boolean, timestamptz) from public, anon;
grant execute on function public.respond_watch_plan(uuid, boolean, timestamptz) to authenticated;
