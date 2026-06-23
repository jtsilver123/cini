-- 0097_tonight_picks_watchlist_only.sql
-- Tonight's Picks are now strictly the user's Want to Watch list (unranked
-- saved titles), never a friend-rec fallback. The card is "watch this tonight":
-- swipe right opens the title's detail page, swipe left dismisses it for tonight
-- (no taste signal — it's already saved). When there's nothing on Want to Watch,
-- the app shows a zero-state pointing to Recs instead of inventing picks.
--
-- friend_count / top_friend are still returned (social proof in the reason line)
-- but no longer pull in titles that aren't already saved. `source` is always
-- 'watchlist' now. Both the in-app deck (tonight_picks) and the evening push
-- (tonight_pick_for) move to watchlist-only so they stay consistent — a user
-- with an empty Want to Watch list simply gets no tonight push.

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
  )
  select wl.movie_id, wl.predicted,
         (select count(*) from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
            where r.movie_id = wl.movie_id and r.score >= 6.7) as friend_count,
         (select p.username from rankings r
            join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
            join profiles p on p.id = r.user_id
            where r.movie_id = wl.movie_id and r.score >= 6.7
            order by r.score desc limit 1) as top_friend,
         'watchlist'::text as source
  from wl
  order by wl.predicted desc, wl.movie_id
  limit p_limit;
$$;
revoke all on function public.tonight_picks(integer) from public, anon;
grant execute on function public.tonight_picks(integer) to authenticated;

create or replace function public.tonight_pick_for(p_user uuid)
returns table(movie_id integer, predicted numeric, friend_count bigint,
              top_friend text, source text)
language sql stable security definer set search_path = public as $$
  with seen as (select movie_id from rankings where user_id = p_user),
  wl as (
    select w.movie_id, coalesce(pc.predicted, 6.5) as predicted
    from watchlist w
    left join predicted_cache pc on pc.user_id = p_user and pc.movie_id = w.movie_id
    where w.user_id = p_user
      and not exists (select 1 from seen s where s.movie_id = w.movie_id)
  ),
  top as (
    select movie_id, predicted from wl
    order by predicted desc, movie_id limit 1
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
         'watchlist'::text as source
  from top t;
$$;
revoke all on function public.tonight_pick_for(uuid) from public, anon, authenticated;
