-- 0072_tonight_picks.sql
-- Return several Tonight's Pick candidates (not just one) so the app can keep
-- the ones that are actually streamable and show a 3-card swipe stack.
create or replace function public.tonight_picks(p_limit integer default 8)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with seen as (select movie_id from rankings where user_id = auth.uid()),
  wl as (
    select w.movie_id, coalesce(pc.predicted, 6.5) as predicted
    from watchlist w
    left join predicted_cache pc on pc.user_id = auth.uid() and pc.movie_id = w.movie_id
    where w.user_id = auth.uid()
      and not exists (select 1 from seen s where s.movie_id = w.movie_id)
  ),
  recs as (
    select r.movie_id, r.score,
           coalesce((select tm.pct / 100.0 from taste_matches tm
                     where tm.user_a = least(auth.uid(), r.user_id)
                       and tm.user_b = greatest(auth.uid(), r.user_id)), 0.5) as match_weight
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
    where r.score >= 6.7
      and not exists (select 1 from seen s where s.movie_id = r.movie_id)
      and not exists (select 1 from watchlist w where w.user_id = auth.uid() and w.movie_id = r.movie_id)
  ),
  rec_agg as (
    select movie_id, round(sum(score * match_weight) / sum(match_weight), 1) as predicted
    from recs group by movie_id
  ),
  pool as (
    select movie_id, predicted + 0.4 as rank_score, predicted, 'watchlist' as source from wl
    union all
    select movie_id, predicted as rank_score, predicted, 'friends' as source from rec_agg
  ),
  best as (
    select distinct on (movie_id) movie_id, rank_score, predicted, source
    from pool order by movie_id, rank_score desc
  )
  select b.movie_id, b.predicted,
         (select count(*) from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
            where r.movie_id = b.movie_id and r.score >= 6.7) as friend_count,
         (select p.username from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
            join profiles p on p.id = r.user_id
            where r.movie_id = b.movie_id and r.score >= 6.7
            order by r.score desc limit 1) as top_friend,
         b.source
  from best b
  order by b.rank_score desc, b.movie_id
  limit p_limit;
$$;
revoke all on function public.tonight_picks(integer) from public, anon;
grant execute on function public.tonight_picks(integer) to authenticated;
