-- "What your school is watching": the titles classmates (same `school`) have
-- ranked most in the last ~6 weeks, for a campus shelf on the feed. Aggregate
-- counts only — excludes the viewer, private accounts, and blocked users.

create or replace function public.school_trending(p_limit int default 12)
returns table(movie_id int, rankers bigint)
language sql stable security definer set search_path = public as $$
  select r.movie_id, count(distinct r.user_id) as rankers
  from rankings r
  join profiles p on p.id = r.user_id
  where p.school is not null
    and p.school = (select school from profiles where id = auth.uid())
    and r.user_id <> auth.uid()
    and not p.is_private
    and not_blocked(r.user_id)
    and r.created_at > now() - interval '45 days'
  group by r.movie_id
  order by rankers desc, max(r.created_at) desc
  limit p_limit;
$$;

revoke execute on function public.school_trending(int) from public, anon;
grant execute on function public.school_trending(int) to authenticated;
