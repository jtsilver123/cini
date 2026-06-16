-- 0068_watch_match_hardening.sql
-- Audit fixes for Watch Match:
--  1. Cap the detector to ONE new nudge per friend-pair per run, so a pair that
--     shares many Want-to-Watch titles can't trigger a burst of pushes. Already-
--     matched pairs are excluded, so a fresh title surfaces on later nights.
--  2. Block self-invites in propose_watch_plan.

create or replace function public.detect_watch_matches()
returns integer
language plpgsql security definer set search_path = public as $$
declare
  m record;
  inserted integer := 0;
begin
  for m in
    select distinct on (lo, hi) movie_id, lo, hi
    from (
      select wa.movie_id,
             least(wa.user_id, wb.user_id)    as lo,
             greatest(wa.user_id, wb.user_id) as hi
      from watchlist wa
      join watchlist wb
        on wb.movie_id = wa.movie_id and wb.user_id > wa.user_id
      join follows f1 on f1.follower_id = wa.user_id and f1.following_id = wb.user_id
      join follows f2 on f2.follower_id = wb.user_id and f2.following_id = wa.user_id
      where not_blocked_pair(wa.user_id, wb.user_id)
        and not exists (select 1 from rankings r
                        where r.movie_id = wa.movie_id and r.user_id in (wa.user_id, wb.user_id))
        and not exists (select 1 from watch_matches wm
                        where wm.movie_id = wa.movie_id
                          and wm.user_low = least(wa.user_id, wb.user_id)
                          and wm.user_high = greatest(wa.user_id, wb.user_id))
    ) cand
    order by lo, hi, movie_id   -- exactly one per pair this run
  loop
    insert into watch_matches (movie_id, user_low, user_high)
    values (m.movie_id, m.lo, m.hi)
    on conflict do nothing;

    insert into notifications (recipient_id, actor_id, kind, movie_id)
    values (m.lo, m.hi, 'watch_match', m.movie_id),
           (m.hi, m.lo, 'watch_match', m.movie_id);
    inserted := inserted + 1;
  end loop;
  return inserted;
end $$;
revoke all on function public.detect_watch_matches() from public, anon, authenticated;

create or replace function public.propose_watch_plan(
  p_movie_id integer, p_invitee uuid, p_proposed_at timestamptz default null)
returns uuid
language plpgsql security definer set search_path = public as $$
declare new_id uuid;
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if auth.uid() = p_invitee then raise exception 'cannot invite yourself'; end if;
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
