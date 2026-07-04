-- 0114_tonight_pick_rotate_and_blend.sql
-- "Why is Tonight's Pick always the same?" — because tonight_picks /
-- tonight_pick_for ordered strictly by predicted score over the Want to Watch
-- list (0097), with a fixed movie_id tie-break and NO day-to-day rotation. The
-- top title therefore led every day (and the push had no rotation at all) until
-- it was ranked or removed; a short watchlist made it feel frozen.
--
-- This reverses the strict watchlist-only rule of 0097 (product decision) and:
--   1) BLENDS in fresh personalized recommendations (recs_for) when the Want to
--      Watch list is thin, so there's always something new to surface.
--   2) ROTATES the pick day-to-day: the eligible titles are ranked by quality
--      (saved titles get a small boost since the user chose them), then the
--      lead cycles through the top of that list by day, so every good candidate
--      gets its turn instead of the single max always winning.
-- Both the in-app deck (tonight_picks) and the evening push (tonight_pick_for)
-- delegate to one workhorse, so they stay consistent.

-- ── recs_for(p_user, p_limit): recs_for_user parameterized by user ──────────
-- Same scoring as recs_for_user (0101) but for an explicit user, so the push
-- (which runs for arbitrary users under the cron/service role) can blend recs
-- too. auth.uid() → p_user throughout, and not_blocked() is inlined against
-- p_user (not_blocked reads auth.uid(), which is null under the service role).
-- Revoked from clients: only the SECURITY DEFINER wrappers below call it.
create or replace function public.recs_for(p_user uuid, p_limit int default 30)
returns table(movie_id int, rec_score numeric, friend_count bigint, top_friend_username text)
language sql stable security definer
set search_path to 'public'
as $$
with
my_rank as (
    select movie_id, score from rankings where user_id = p_user
),
my_stats as (
    select coalesce(avg(score), 6.5) as mu, count(*)::int as n from my_rank
),
my_movies as (
    select movie_id from my_rank
    union select movie_id from watchlist  where user_id = p_user
    union select movie_id from rec_passes where user_id = p_user
),
genre_signal as (
    select g.genre, (r.score - st.mu) as dev, 1.0::numeric as wt
    from my_rank r cross join my_stats st
    join movies m on m.tmdb_id = r.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    union all
    select g.genre, 0.7::numeric, 0.4::numeric
    from watchlist w
    join movies m on m.tmdb_id = w.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where w.user_id = p_user
    union all
    select g.genre, -1.5::numeric, 0.6::numeric
    from rec_passes p
    join movies m on m.tmdb_id = p.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where p.user_id = p_user
),
genre_dev as (
    select genre, sum(wt * dev) / (sum(wt) + 4) as dev
    from genre_signal group by genre
),
dir_dev as (
    select m.director, sum(r.score - st.mu) / (count(*) + 3) as dev
    from my_rank r cross join my_stats st
    join movies m on m.tmdb_id = r.movie_id
    where m.director is not null
    group by m.director
),
community as (
    select r.movie_id, (sum(r.score) + 6.5 * 5) / (count(*) + 5) as cscore
    from rankings r group by r.movie_id
),
friend_ranks as (
    select r.movie_id, r.score, p.username,
           greatest(
             coalesce((select tm.pct / 100.0 from taste_matches tm
                       where tm.user_a = least(p_user, r.user_id)
                         and tm.user_b = greatest(p_user, r.user_id)), 0.5),
             0.05) as mw
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = p_user
    join profiles p on p.id = r.user_id
    where r.score >= 6.7
      and not exists (select 1 from blocks b
                      where (b.blocker_id = p_user and b.blocked_id = r.user_id)
                         or (b.blocker_id = r.user_id and b.blocked_id = p_user))
      and r.movie_id not in (select movie_id from my_movies)
),
friend_agg as (
    select fr.movie_id,
           sum(fr.score * fr.mw) / sum(fr.mw) as wavg,
           count(*) as cnt,
           (array_agg(fr.username order by fr.score * fr.mw desc))[1] as top_friend
    from friend_ranks fr group by fr.movie_id
),
candidates as (
    select movie_id from friend_agg
    union
    select m.tmdb_id from movies m
    where exists (select 1 from rankings r where r.movie_id = m.tmdb_id)
),
cand_personal as (
    select c.movie_id,
           coalesce(avg(gd.dev), 0) as gdev,
           coalesce(max(dd.dev), 0) as ddev
    from candidates c
    join movies m on m.tmdb_id = c.movie_id
    left join lateral unnest(m.genres) as g(genre) on true
    left join genre_dev gd on gd.genre = g.genre
    left join dir_dev  dd on dd.director = m.director
    group by c.movie_id
),
uw as (
    select mu, (n::numeric / (n + 15)) as pc from my_stats
)
select c.movie_id,
       round((
             (0.60 * uw.pc)
                 * least(10, greatest(0, uw.mu + cp.gdev + 0.5 * cp.ddev))
           + (case when fa.movie_id is not null then 0.30 else 0 end)
                 * least(10, fa.wavg * (1 + least(fa.cnt - 1, 3) * 0.08))
           + (1 - 0.60 * uw.pc - (case when fa.movie_id is not null then 0.30 else 0 end))
                 * cm.cscore
       )::numeric, 1) as rec_score,
       coalesce(fa.cnt, 0) as friend_count,
       fa.top_friend as top_friend_username
from candidates c
join cand_personal cp on cp.movie_id = c.movie_id
join community cm on cm.movie_id = c.movie_id
left join friend_agg fa on fa.movie_id = c.movie_id
cross join uw
where c.movie_id not in (select movie_id from my_movies)
order by rec_score desc, coalesce(fa.cnt, 0) desc
limit p_limit;
$$;
revoke all on function public.recs_for(uuid, int) from public, anon, authenticated;

-- recs_for_user now just delegates (unchanged behavior for existing callers).
create or replace function public.recs_for_user(p_limit int default 30)
returns table(movie_id int, rec_score numeric, friend_count bigint, top_friend_username text)
language sql stable security definer set search_path to 'public'
as $$ select * from public.recs_for(auth.uid(), p_limit); $$;
revoke execute on function public.recs_for_user(int) from public, anon;
grant execute on function public.recs_for_user(int) to authenticated;

-- ── tonight_pool(p_user, p_limit): the shared, blended, rotated source ───────
create or replace function public.tonight_pool(p_user uuid, p_limit integer)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with
  day as (select (extract(epoch from now()) / 86400)::int as d),
  seen as (select movie_id from rankings where user_id = p_user),
  -- Want to Watch first: their explicit picks, nudged up so saved titles still
  -- lead a same-scored rec.
  wl as (
    select w.movie_id,
           coalesce(pc.predicted, 6.5) + 0.5 as sc,
           'watchlist'::text as source
    from watchlist w
    left join predicted_cache pc on pc.user_id = p_user and pc.movie_id = w.movie_id
    where w.user_id = p_user
      and not exists (select 1 from seen s where s.movie_id = w.movie_id)
  ),
  -- Fresh recommendations to blend in (recs_for already excludes ranked /
  -- saved / passed titles), so a thin watchlist still surfaces something new.
  rec as (
    select r.movie_id, r.rec_score as sc, 'rec'::text as source
    from recs_for(p_user, 20) r
    where not exists (select 1 from wl where wl.movie_id = r.movie_id)
  ),
  cand as (select * from wl union all select * from rec),
  ranked as (
    select movie_id, sc, source,
           row_number() over (order by sc desc, movie_id) as rn,
           count(*) over () as total
    from cand
  ),
  -- Rotate only within the top of the quality-ranked list so every DAY a
  -- different strong candidate leads, but a weak tail never gets promoted.
  pool as (select greatest(1, least(max(total), 12)) as ps from ranked)
  select r.movie_id, r.sc::numeric as predicted,
         (select count(*) from rankings rr
            join follows f on f.following_id = rr.user_id and f.follower_id = p_user
            where rr.movie_id = r.movie_id and rr.score >= 6.7) as friend_count,
         (select p.username from rankings rr
            join follows f on f.following_id = rr.user_id and f.follower_id = p_user
            join profiles p on p.id = rr.user_id
            where rr.movie_id = r.movie_id and rr.score >= 6.7
            order by rr.score desc limit 1) as top_friend,
         r.source
  from ranked r cross join day cross join pool
  order by
    case when r.rn <= pool.ps
         then ((r.rn - 1 - (day.d % pool.ps) + pool.ps) % pool.ps)
         else 1000 + r.rn end,
    r.movie_id
  limit p_limit;
$$;
revoke all on function public.tonight_pool(uuid, integer) from public, anon, authenticated;

-- ── Public wrappers delegate to the workhorse ───────────────────────────────
create or replace function public.tonight_picks(p_limit integer default 8)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  select * from public.tonight_pool(auth.uid(), p_limit);
$$;
revoke all on function public.tonight_picks(integer) from public, anon;
grant execute on function public.tonight_picks(integer) to authenticated;

create or replace function public.tonight_pick_for(p_user uuid)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  select * from public.tonight_pool(p_user, 1);
$$;
revoke all on function public.tonight_pick_for(uuid) from public, anon, authenticated;
