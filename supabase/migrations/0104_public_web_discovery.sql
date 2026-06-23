-- 0104_public_web_discovery.sql
-- Discovery + depth for the public web layer (docs/WEB_PLAN.md): charts/best-of,
-- a public taste-match page, richer title pages, and a profile's public lists.
-- All anon-callable SECURITY DEFINER, all aggregate-or-public-only. Community
-- aggregates already pool every ranking (no individual is identified); anything
-- attributed to a person is gated to not is_private accounts.

-- ---- Charts / "Best of" ---------------------------------------------------
-- Top titles by a Bayesian-shrunk community score (so a single 10/10 can't top
-- a beloved title with 200 ratings). Filterable by media kind, genre, decade.
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
    group by m.tmdb_id, m.media_kind, m.title, m.poster_path, m.release_year
    order by bayes desc, cnt desc
    limit greatest(1, least(p_limit, 100))
  ) s;
$$;
revoke all on function public.public_charts(text, text, int, int) from public;
grant execute on function public.public_charts(text, text, int, int) to anon, authenticated;

-- ---- Public taste match ---------------------------------------------------
-- Mirrors compute_taste_match (Spearman-style rank correlation over commonly
-- ranked titles, mapped to 0-100, needs >= 3 in common), but resolves usernames
-- and gates BOTH users on not is_private. Also returns the shared titles with
-- both scores so the page can show where they agree / clash. NULL if either
-- handle is missing/private.
create or replace function public.public_taste_match(p_a text, p_b text)
returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  ua uuid; ub uuid; v_rho numeric; v_n int; shared jsonb;
begin
  select id into ua from profiles where lower(username) = lower(p_a) and not is_private;
  select id into ub from profiles where lower(username) = lower(p_b) and not is_private;
  if ua is null or ub is null or ua = ub then return null; end if;

  select corr(a.rk, b.rk), count(*) into v_rho, v_n
  from (select movie_id, rank() over (order by bucket, position, movie_id) as rk
        from rankings where user_id = ua) a
  join (select movie_id, rank() over (order by bucket, position, movie_id) as rk
        from rankings where user_id = ub) b using (movie_id);

  select coalesce(jsonb_agg(jsonb_build_object(
           'movie_id',     m.tmdb_id,
           'title',        m.title,
           'poster_path',  m.poster_path,
           'release_year', m.release_year,
           'media_kind',   m.media_kind,
           'score_a',      ra.score,
           'score_b',      rb.score
         ) order by (ra.score + rb.score) desc), '[]'::jsonb)
  into shared
  from rankings ra
  join rankings rb on rb.movie_id = ra.movie_id and rb.user_id = ub
  join movies m on m.tmdb_id = ra.movie_id
  where ra.user_id = ua;

  return jsonb_build_object(
    'a', (select jsonb_build_object('username', username, 'display_name', display_name, 'avatar_url', avatar_url) from profiles where id = ua),
    'b', (select jsonb_build_object('username', username, 'display_name', display_name, 'avatar_url', avatar_url) from profiles where id = ub),
    'shared_count', coalesce(v_n, 0),
    'match_pct', case when v_n >= 3 and v_rho is not null then round((v_rho + 1) / 2 * 100, 0) else null end,
    'shared', shared
  );
end $$;
revoke all on function public.public_taste_match(text, text) from public;
grant execute on function public.public_taste_match(text, text) to anon, authenticated;

-- ---- Title page extras ----------------------------------------------------
-- Who (publicly) ranked a title + their scores, and public notes/reviews — both
-- restricted to not is_private accounts (and not is_private notes).
create or replace function public.public_title_extras(p_movie_id int)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'rankers', coalesce((
      select jsonb_agg(x.j order by x.sc desc)
      from (
        select jsonb_build_object(
                 'username', p.username, 'display_name', p.display_name,
                 'avatar_url', p.avatar_url, 'score', r.score) as j,
               r.score as sc
        from rankings r join profiles p on p.id = r.user_id
        where r.movie_id = p_movie_id and not p.is_private
        order by r.score desc
        limit 30
      ) x), '[]'::jsonb),
    'notes', coalesce((
      select jsonb_agg(y.j order by y.at desc)
      from (
        select jsonb_build_object(
                 'username', p.username, 'display_name', p.display_name,
                 'avatar_url', p.avatar_url, 'body', n.body,
                 'spoilers', n.contains_spoilers) as j,
               n.created_at as at
        from notes n join profiles p on p.id = n.user_id
        where n.movie_id = p_movie_id and not n.is_private and not p.is_private
        order by n.created_at desc
        limit 20
      ) y), '[]'::jsonb)
  );
$$;
revoke all on function public.public_title_extras(int) from public;
grant execute on function public.public_title_extras(int) to anon, authenticated;

-- ---- A public profile's public lists --------------------------------------
create or replace function public.public_profile_lists(p_username text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'id',         cl.id,
           'name',       cl.name,
           'media_kind', cl.media_kind,
           'count',      (select count(*) from custom_list_items i where i.list_id = cl.id)
         ) order by cl.created_at desc), '[]'::jsonb)
  from custom_lists cl
  join profiles p on p.id = cl.user_id
  where lower(p.username) = lower(p_username)
    and not p.is_private and not cl.is_private;
$$;
revoke all on function public.public_profile_lists(text) from public;
grant execute on function public.public_profile_lists(text) to anon, authenticated;
