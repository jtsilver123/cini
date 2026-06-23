-- 0107_public_slug_in_lists.sql
-- Add the title slug to the discovery/list RPC outputs so the web pages can link
-- straight to the canonical /title/<slug> instead of /m/?id= (which 301s). Same
-- bodies as 0102/0104/0105, just with 'slug', m.slug added to each title item.

create or replace function public.public_rankings(p_username text, p_limit int default 250)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.j order by s.sc desc, s.pos asc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'movie_id',     r.movie_id,
             'slug',         m.slug,
             'media_kind',   m.media_kind,
             'title',        m.title,
             'poster_path',  m.poster_path,
             'release_year', m.release_year,
             'bucket',       r.bucket,
             'score',        r.score
           ) as j,
           r.score as sc, r.position as pos
    from rankings r
    join profiles p on p.id = r.user_id
    join movies m on m.tmdb_id = r.movie_id
    where lower(p.username) = lower(p_username)
      and not p.is_private
    order by r.score desc, r.position asc
    limit greatest(1, least(p_limit, 1000))
  ) s;
$$;
revoke all on function public.public_rankings(text, int) from public;
grant execute on function public.public_rankings(text, int) to anon, authenticated;

create or replace function public.public_list(p_list_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id',         cl.id,
    'name',       cl.name,
    'media_kind', cl.media_kind,
    'created_at', cl.created_at,
    'owner', jsonb_build_object(
      'username',     p.username,
      'display_name', p.display_name,
      'avatar_url',   p.avatar_url
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'movie_id',     m.tmdb_id,
               'slug',         m.slug,
               'media_kind',   m.media_kind,
               'title',        m.title,
               'poster_path',  m.poster_path,
               'release_year', m.release_year
             ) order by cli.position asc, cli.created_at asc)
      from custom_list_items cli
      join movies m on m.tmdb_id = cli.movie_id
      where cli.list_id = cl.id
    ), '[]'::jsonb)
  )
  from custom_lists cl
  join profiles p on p.id = cl.user_id
  where cl.id = p_list_id
    and not cl.is_private
    and not p.is_private;
$$;
revoke all on function public.public_list(uuid) from public;
grant execute on function public.public_list(uuid) to anon, authenticated;

create or replace function public.public_charts(
  p_media_kind text default null,
  p_genre text default null,
  p_decade int default null,
  p_limit int default 50)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.j order by s.bayes desc, s.cnt desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'movie_id',     m.tmdb_id,
             'slug',         m.slug,
             'media_kind',   m.media_kind,
             'title',        m.title,
             'poster_path',  m.poster_path,
             'release_year', m.release_year,
             'avg',          round(avg(r.score), 1),
             'count',        count(*)
           ) as j,
           (sum(r.score) + 6.5 * 5) / (count(*) + 5) as bayes,
           count(*) as cnt
    from rankings r
    join movies m on m.tmdb_id = r.movie_id
    where (p_media_kind is null or m.media_kind = p_media_kind)
      and (p_genre is null or m.genres @> array[p_genre])
      and (p_decade is null or (m.release_year >= p_decade and m.release_year < p_decade + 10))
    group by m.tmdb_id, m.slug, m.media_kind, m.title, m.poster_path, m.release_year
    order by bayes desc, cnt desc
    limit greatest(1, least(p_limit, 100))
  ) s;
$$;
revoke all on function public.public_charts(text, text, int, int) from public;
grant execute on function public.public_charts(text, text, int, int) to anon, authenticated;

create or replace function public.public_search_titles(p_q text, p_limit int default 20)
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(s.j order by s.rc desc, s.sim desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'movie_id', m.tmdb_id,
             'slug', m.slug,
             'title', m.title,
             'release_year', m.release_year,
             'poster_path', m.poster_path,
             'media_kind', m.media_kind,
             'avg', (select round(avg(r.score), 1) from rankings r where r.movie_id = m.tmdb_id),
             'count', (select count(*) from rankings r where r.movie_id = m.tmdb_id)
           ) as j,
           (select count(*) from rankings r where r.movie_id = m.tmdb_id) as rc,
           similarity(m.title, p_q) as sim
    from movies m
    where m.title ilike '%' || p_q || '%'
       or m.title % p_q
    order by rc desc, sim desc
    limit greatest(1, least(p_limit, 40))
  ) s;
$$;
revoke all on function public.public_search_titles(text, int) from public;
grant execute on function public.public_search_titles(text, int) to anon, authenticated;
