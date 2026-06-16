-- 0062_tonight_pick.sql
-- "Tonight's Pick": one personalized "watch this tonight" per user, the daily
-- hook. Prefers the highest-predicted Want-to-Watch title (they already chose
-- it — tonight's the night), then falls back to a friend-loved rec. Returns the
-- pick plus the inputs the app composes a reason line from ("we think you'll
-- rate it 8.9 · 3 friends loved it").
--
-- Two functions, mirroring the predicted_scores/predicted_scores_for split:
--   tonight_pick_for(p_user) — service-role only (the nightly push job).
--   tonight_pick()           — the in-app card, gated to auth.uid().

create or replace function public.tonight_pick_for(p_user uuid)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with seen as (
    select movie_id from rankings where user_id = p_user
  ),
  -- Want to Watch the user hasn't ranked yet, scored by the cached prediction.
  wl as (
    select w.movie_id, coalesce(pc.predicted, 6.5) as predicted
    from watchlist w
    left join predicted_cache pc
      on pc.user_id = p_user and pc.movie_id = w.movie_id
    where w.user_id = p_user
      and not exists (select 1 from seen s where s.movie_id = w.movie_id)
  ),
  -- Friend-loved unseen titles not already on their Want to Watch.
  recs as (
    select r.movie_id, r.score,
           coalesce(
             (select tm.pct / 100.0 from taste_matches tm
              where tm.user_a = least(p_user, r.user_id)
                and tm.user_b = greatest(p_user, r.user_id)), 0.5) as match_weight
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = p_user
    where r.score >= 6.7
      and not exists (select 1 from seen s where s.movie_id = r.movie_id)
      and not exists (select 1 from watchlist w
                      where w.user_id = p_user and w.movie_id = r.movie_id)
  ),
  rec_agg as (
    select movie_id,
           round(sum(score * match_weight) / sum(match_weight), 1) as predicted
    from recs group by movie_id
  ),
  -- Pool both sources; a Want-to-Watch title gets a small intent boost.
  pool as (
    select movie_id, predicted + 0.4 as rank_score, predicted, 'watchlist' as source from wl
    union all
    select movie_id, predicted as rank_score, predicted, 'friends' as source from rec_agg
  ),
  best as (
    select distinct on (movie_id) movie_id, rank_score, predicted, source
    from pool
    order by movie_id, rank_score desc
  ),
  top as (
    select movie_id, predicted, source
    from best
    order by rank_score desc, movie_id
    limit 1
  )
  select t.movie_id, t.predicted,
         (select count(*) from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = p_user
            where r.movie_id = t.movie_id and r.score >= 6.7) as friend_count,
         (select p.username from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = p_user
            join profiles p on p.id = r.user_id
            where r.movie_id = t.movie_id and r.score >= 6.7
            order by r.score desc limit 1) as top_friend,
         t.source
  from top t;
$$;

create or replace function public.tonight_pick()
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  select * from public.tonight_pick_for(auth.uid());
$$;

-- tonight_pick_for is service-role only (a user must not pass someone else's
-- id and read their pick); the in-app wrapper is gated to the caller.
revoke all on function public.tonight_pick_for(uuid) from public, anon, authenticated;
revoke all on function public.tonight_pick() from public, anon;
grant execute on function public.tonight_pick() to authenticated;
