-- 0103_public_title.sql
-- Anon-callable title page data for the public web layer (trycini.com/m/?id=).
-- Returns a title's TMDB-cached metadata PLUS Cini's own community score and a
-- score distribution — all aggregate, no PII, so it's safe for logged-out web.
-- Returns the movie even when nobody's ranked it yet (community = null then), so
-- the page always renders. NULL only when the tmdb_id isn't cached at all.
create or replace function public.public_title(p_movie_id int)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tmdb_id',       m.tmdb_id,
    'media_kind',    m.media_kind,
    'title',         m.title,
    'release_year',  m.release_year,
    'poster_path',   m.poster_path,
    'backdrop_path', m.backdrop_path,
    'overview',      m.overview,
    'genres',        to_jsonb(m.genres),
    'runtime_minutes', m.runtime_minutes,
    'director',      m.director,
    'community', (
      select case when count(*) = 0 then null else jsonb_build_object(
               'avg',   round(avg(r.score), 1),
               'count', count(*)
             ) end
      from rankings r where r.movie_id = m.tmdb_id
    ),
    'histogram', coalesce((
      select jsonb_agg(jsonb_build_object('floor', h.fl, 'n', h.cnt) order by h.fl)
      from (
        select floor(r.score)::int as fl, count(*) as cnt
        from rankings r where r.movie_id = m.tmdb_id
        group by floor(r.score)
      ) h
    ), '[]'::jsonb)
  )
  from movies m
  where m.tmdb_id = p_movie_id;
$$;
revoke all on function public.public_title(int) from public;
grant execute on function public.public_title(int) to anon, authenticated;
