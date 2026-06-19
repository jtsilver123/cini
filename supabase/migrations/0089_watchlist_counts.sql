-- Privacy-safe aggregate: how many people have each title on Want to Watch.
-- Returns only counts (no user rows), so SECURITY DEFINER is intentional.
create or replace function public.watchlist_counts(p_movie_ids int[])
returns table(movie_id int, n bigint)
language sql stable security definer set search_path = public as $$
  select movie_id, count(*)::bigint
  from public.watchlist
  where movie_id = any(p_movie_ids)
  group by movie_id
$$;
grant execute on function public.watchlist_counts(int[]) to authenticated;
