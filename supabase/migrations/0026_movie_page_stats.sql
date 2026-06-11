-- One round trip for the movie page's public aggregates (community
-- score, histogram, labels, performances) instead of four. Composes the
-- EXISTING view/RPCs so the numbers cannot drift from the old paths.
-- (Applied to prod via MCP on 2026-06-11.)
create or replace function public.movie_page_stats(p_movie_id int)
returns json
language sql stable security definer
set search_path to 'public'
as $$
  select json_build_object(
    'community',
      (select row_to_json(c) from movie_community_scores c
       where c.movie_id = p_movie_id),
    'histogram',
      (select coalesce(json_agg(row_to_json(h)), '[]'::json)
       from movie_score_histogram(p_movie_id) h),
    'labels',
      (select coalesce(json_agg(l.name), '[]'::json)
       from movie_top_labels(p_movie_id) l),
    'performances',
      (select coalesce(json_agg(json_build_object(
                 'tmdb_person_id', fp.tmdb_person_id,
                 'person_name', fp.person_name,
                 'profile_path', fp.profile_path)), '[]'::json)
       from favorite_performances fp
       where fp.movie_id = p_movie_id)
  );
$$;

revoke execute on function public.movie_page_stats(int) from public, anon;
grant execute on function public.movie_page_stats(int) to authenticated;
