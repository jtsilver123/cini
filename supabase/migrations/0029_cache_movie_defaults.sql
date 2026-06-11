-- The app's Encodable omits nil fields, so cache_movie calls for sparse
-- movies (plain search results) didn't match the function signature
-- (PGRST202) — the movie was never cached and the following watchlist/
-- rankings insert hit its FK ("Couldn't save" on bookmark and rank).
-- Defaults make omitted params match; coalesce keeps a sparse re-cache
-- from wiping richer data already on the row.
drop function if exists public.cache_movie(int, text, text, smallint, text, text, text[], text, int, text, text);
create function public.cache_movie(
  p_tmdb_id int,
  p_media_kind text,
  p_title text,
  p_release_year smallint default null,
  p_poster_path text default null,
  p_backdrop_path text default null,
  p_genres text[] default '{}',
  p_certification text default null,
  p_runtime_minutes int default null,
  p_director text default null,
  p_overview text default null
)
returns void
language sql
security definer
set search_path to 'public'
as $$
    insert into movies (tmdb_id, media_kind, title, release_year, poster_path,
                        backdrop_path, genres, certification, runtime_minutes,
                        director, overview, cached_at)
    values (p_tmdb_id, p_media_kind, p_title, p_release_year, p_poster_path,
            p_backdrop_path, p_genres, p_certification, p_runtime_minutes,
            p_director, p_overview, now())
    on conflict (tmdb_id) do update set
        title = excluded.title,
        release_year = coalesce(excluded.release_year, movies.release_year),
        poster_path = coalesce(excluded.poster_path, movies.poster_path),
        backdrop_path = coalesce(excluded.backdrop_path, movies.backdrop_path),
        genres = case when excluded.genres = '{}' then movies.genres else excluded.genres end,
        certification = coalesce(excluded.certification, movies.certification),
        runtime_minutes = coalesce(excluded.runtime_minutes, movies.runtime_minutes),
        director = coalesce(excluded.director, movies.director),
        overview = coalesce(excluded.overview, movies.overview),
        cached_at = now();
$$;

-- Recreation resets grants to PUBLIC — re-apply the 0025 policy.
revoke execute on function public.cache_movie(int, text, text, smallint, text, text, text[], text, int, text, text) from public, anon;
grant execute on function public.cache_movie(int, text, text, smallint, text, text, text[], text, int, text, text) to authenticated;
