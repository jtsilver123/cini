-- 0117_tonight_pool_fixes.sql
-- Audit fixes for 0114's tonight_pool:
--
-- 1) The +0.5 watchlist sort nudge LEAKED into the returned `predicted`:
--    an uncached saved title came back as exactly 7.0 and crossed the
--    app's `>= 7.0` display gate, fabricating "We think you'll rate it
--    7.0" for a title the model knows nothing about (and showing every
--    real prediction 0.5 high). The nudge is now sort-only.
-- 2) The rotation day used `(epoch/86400)::int`, and numeric→int ROUNDS —
--    so the "day" flipped at noon UTC, swapping the lead pick mid-evening
--    east of UTC. Now floor().
-- 3) The recs blend ran the full recs_for pipeline (the heavy Recs-screen
--    query) on EVERY feed load for every user. Per the original design
--    ("blend in when the Want to Watch list is thin"), recs now only blend
--    when fewer than 8 unranked saved titles remain — a healthy watchlist
--    never pays for it, and its owner sees their own picks anyway.

create or replace function public.tonight_pool(p_user uuid, p_limit integer)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with
  day as (select floor(extract(epoch from now()) / 86400)::int as d),
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
