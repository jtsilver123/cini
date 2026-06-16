-- 0067_movie_watchlist_friends.sql
-- Friends (you follow, not blocked) who also have this title on their Want to
-- Watch — powers the movie page's "invite a friend to watch together" row.
create or replace function public.movie_watchlist_friends(p_movie_id integer)
returns table(user_id uuid, username text, display_name text, avatar_url text)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from watchlist w
  join follows f on f.following_id = w.user_id and f.follower_id = auth.uid()
  join profiles p on p.id = w.user_id
  where w.movie_id = p_movie_id
    and not_blocked_pair(auth.uid(), w.user_id)
  order by p.username;
$$;
revoke all on function public.movie_watchlist_friends(integer) from public, anon;
grant execute on function public.movie_watchlist_friends(integer) to authenticated;
