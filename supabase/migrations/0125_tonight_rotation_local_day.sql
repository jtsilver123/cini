-- Mirrors prod migration `tonight_rotation_local_day`.
--
-- Tonight's Pick rotated on the UTC day, which flips at 7pm ET / 4pm PT —
-- so the 7pm-local push and the in-app deck could name DIFFERENT movies the
-- same evening, and the "tonight" pick changed mid-evening for US users.
-- Rotate on the user's LOCAL day instead (profiles.timezone, the same
-- column that already times the evening push; UTC when unset). Everything
-- else in tonight_pool is unchanged from 0117.

create or replace function public.tonight_pool(p_user uuid, p_limit integer)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with
  -- The user's LOCAL day number: `now() at time zone tz` yields local wall
  -- time, so the day boundary lands at the user's midnight, not UTC's.
  day as (
    select floor(extract(epoch from (now() at time zone coalesce(
             (select nullif(timezone, '') from profiles where id = p_user),
             'UTC'))) / 86400)::int as d
  ),
  seen as (select movie_id from rankings where user_id = p_user),
  -- Want to Watch first: their explicit picks. `sort_sc` carries a +0.5
  -- nudge so a saved title outranks a same-scored rec; `predicted` stays
  -- the honest value the app may display.
  wl as (
    select w.movie_id,
           coalesce(pc.predicted, 6.5) as predicted,
           coalesce(pc.predicted, 6.5) + 0.5 as sort_sc,
           'watchlist'::text as source
    from watchlist w
    left join predicted_cache pc on pc.user_id = p_user and pc.movie_id = w.movie_id
    where w.user_id = p_user
      and not exists (select 1 from seen s where s.movie_id = w.movie_id)
  ),
  -- Fresh recommendations, only when the watchlist is thin (recs_for is
  -- the heavy Recs-screen query — don't run it when saved titles already
  -- fill the deck).
  rec as (
    select r.movie_id, r.rec_score as predicted, r.rec_score as sort_sc,
           'rec'::text as source
    from recs_for(p_user, 20) r
    where (select count(*) from wl) < 8
      and not exists (select 1 from wl where wl.movie_id = r.movie_id)
  ),
  cand as (select * from wl union all select * from rec),
  ranked as (
    select movie_id, predicted, source,
           row_number() over (order by sort_sc desc, movie_id) as rn,
           count(*) over () as total
    from cand
  ),
  -- Rotate only within the top of the quality-ranked list so every DAY a
  -- different strong candidate leads, but a weak tail never gets promoted.
  pool as (select greatest(1, least(max(total), 12)) as ps from ranked)
  select r.movie_id, r.predicted,
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
