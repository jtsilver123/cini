-- 0073_show_progress_caught_up.sql
-- Track whether a viewer is "all caught up" on a show they're watching, so the
-- feed's watching-stories can show a distinct (caught-up) ring/badge.

alter table public.show_progress
  add column if not exists caught_up boolean not null default false;

-- set_show_progress now carries the caught-up flag (the "I'm caught up" button
-- sets true; manual stepper edits set false). Replaces the 3-arg version.
drop function if exists public.set_show_progress(integer, integer, integer);
create or replace function public.set_show_progress(
  p_show_id integer, p_season integer, p_episode integer, p_caught_up boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into show_progress (user_id, show_id, season, episode, caught_up, updated_at)
  values (auth.uid(), p_show_id, p_season, p_episode, p_caught_up, now())
  on conflict (user_id, show_id) do update
    set season = excluded.season, episode = excluded.episode,
        caught_up = excluded.caught_up, updated_at = now();
  delete from watchlist where user_id = auth.uid() and movie_id = p_show_id;
end $$;
revoke all on function public.set_show_progress(integer, integer, integer, boolean) from public, anon;
grant execute on function public.set_show_progress(integer, integer, integer, boolean) to authenticated;

-- friends_watching now returns caught_up (return shape changes → drop+recreate).
drop function if exists public.friends_watching();
create or replace function public.friends_watching()
returns table(user_id uuid, username text, display_name text, avatar_url text,
              show_id integer, title text, poster_path text,
              season integer, episode integer, caught_up boolean, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.user_id, p.username, p.display_name, p.avatar_url,
         sp.show_id, m.title, m.poster_path, sp.season, sp.episode, sp.caught_up, sp.updated_at
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
