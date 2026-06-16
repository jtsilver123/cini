-- 0075_movie_watching_friends.sql
-- Friends (you follow, can view) currently WATCHING a given show — the
-- counterpart to movie_watchlist_friends (who WANT to watch). Powers the
-- Beli-style "N friends are watching" row + popup on the detail page.
create or replace function public.movie_watching_friends(p_movie_id integer)
returns table(user_id uuid, username text, display_name text, avatar_url text,
              season integer, episode integer, caught_up boolean)
language sql stable security definer set search_path = public as $$
  select p.id, p.username, p.display_name, p.avatar_url, sp.season, sp.episode, sp.caught_up
  from show_progress sp
  join follows f on f.following_id = sp.user_id and f.follower_id = auth.uid()
  join profiles p on p.id = sp.user_id
  where sp.show_id = p_movie_id and can_view(sp.user_id)
  order by p.username;
$$;
revoke all on function public.movie_watching_friends(integer) from public, anon;
grant execute on function public.movie_watching_friends(integer) to authenticated;
