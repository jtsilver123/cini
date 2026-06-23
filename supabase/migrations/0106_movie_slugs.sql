-- 0106_movie_slugs.sql
-- Canonical keyword-rich title URLs. We collapse the two title surfaces — the
-- static /reviews/<slug>/ pages and the SSR /m/?id= page — into ONE canonical
-- URL per title: /title/<slug>, server-rendered with the live community score.
-- This adds the slug↔tmdb_id mapping the web layer needs to resolve a slug.
--
-- slugify() mirrors scripts/build_review_pages.py exactly (lowercase, runs of
-- non-alphanumerics → "-", trimmed, "-<year>" suffix) so the slugs already in
-- the sitemap / shared review links resolve to the same movie.
create or replace function public.slugify(p_text text, p_year int)
returns text language sql immutable as $$
  select case when p_year is not null
    then trim(both '-' from regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g')) || '-' || p_year::text
    else trim(both '-' from regexp_replace(lower(coalesce(p_text, '')), '[^a-z0-9]+', '-', 'g'))
  end;
$$;

alter table public.movies add column if not exists slug text;
update public.movies set slug = public.slugify(title, release_year) where slug is null;
create index if not exists movies_slug_idx on public.movies(slug);

-- Keep slug in sync as titles are cached/updated (cache_movie upserts movies).
create or replace function public.movies_set_slug() returns trigger
language plpgsql set search_path = public as $$
begin
  new.slug := public.slugify(new.title, new.release_year);
  return new;
end $$;
drop trigger if exists trg_movies_slug on public.movies;
create trigger trg_movies_slug
  before insert or update of title, release_year on public.movies
  for each row execute function public.movies_set_slug();

-- Re-create public_title to include the slug (so the /m/?id= function can 301 to
-- the canonical /title/<slug>). Body otherwise identical to 0103.
create or replace function public.public_title(p_movie_id int)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tmdb_id',       m.tmdb_id,
    'slug',          m.slug,
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

-- Resolve a slug → the full title payload (reuses public_title).
create or replace function public.public_title_by_slug(p_slug text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select public.public_title(m.tmdb_id)
  from movies m
  where m.slug = p_slug
  order by (select count(*) from rankings r where r.movie_id = m.tmdb_id) desc
  limit 1;
$$;
revoke all on function public.public_title_by_slug(text) from public;
grant execute on function public.public_title_by_slug(text) to anon, authenticated;
