-- 0105_public_search.sql
-- Anon-callable search for the public web (trycini.com/search): find public
-- members and titles. Both are SECURITY DEFINER and only surface public data —
-- members gated on not is_private; titles are TMDB-cached metadata (already
-- public). Uses the existing pg_trgm indexes on profiles.username and
-- movies.title. NOTE: pg_trgm lives in the `extensions` schema on Supabase, so
-- the search_path must include it for similarity()/% to resolve.

-- Public members matching a query (username or display name). Ranked by how
-- active they are (more rankings first), then text similarity.
create or replace function public.public_search_members(p_q text, p_limit int default 20)
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(s.j order by s.rc desc, s.sim desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'username', p.username,
             'display_name', p.display_name,
             'avatar_url', p.avatar_url,
             'ranked_count', (select count(*) from rankings r where r.user_id = p.id)
           ) as j,
           (select count(*) from rankings r where r.user_id = p.id) as rc,
           greatest(similarity(p.username, p_q),
                    similarity(coalesce(p.display_name, ''), p_q)) as sim
    from profiles p
    where not p.is_private
      and (p.username ilike '%' || p_q || '%'
           or p.display_name ilike '%' || p_q || '%'
           or p.username % p_q)
    order by rc desc, sim desc
    limit greatest(1, least(p_limit, 40))
  ) s;
$$;
revoke all on function public.public_search_members(text, int) from public;
grant execute on function public.public_search_members(text, int) to anon, authenticated;

-- Titles in Cini's catalog matching a query. Ranked by how many people ranked
-- it (most-known first), then text similarity. Includes the community score.
create or replace function public.public_search_titles(p_q text, p_limit int default 20)
returns jsonb
language sql stable security definer set search_path = public, extensions as $$
  select coalesce(jsonb_agg(s.j order by s.rc desc, s.sim desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'movie_id', m.tmdb_id,
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
