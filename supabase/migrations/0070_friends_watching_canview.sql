-- 0070_friends_watching_canview.sql
-- Defense-in-depth from the audit: friends_watching already requires a follow
-- edge (and a follow edge to a private account only exists after approval), but
-- add an explicit can_view() gate so visibility can never drift from the rest of
-- the app's rules — a private account's "currently watching" is only ever shown
-- to viewers who can_view them.
create or replace function public.friends_watching()
returns table(user_id uuid, username text, display_name text, avatar_url text,
              show_id integer, title text, poster_path text,
              season integer, episode integer, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.user_id, p.username, p.display_name, p.avatar_url,
         sp.show_id, m.title, m.poster_path, sp.season, sp.episode, sp.updated_at
  from show_progress sp
  join follows f on f.following_id = sp.user_id and f.follower_id = auth.uid()
  join profiles p on p.id = sp.user_id
  join movies m on m.tmdb_id = sp.show_id
  where can_view(sp.user_id)
  order by sp.updated_at desc
  limit 30;
$$;
revoke all on function public.friends_watching() from public, anon;
grant execute on function public.friends_watching() to authenticated;
