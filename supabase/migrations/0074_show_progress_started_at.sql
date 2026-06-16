-- 0074_show_progress_started_at.sql
-- Track when a user STARTED a show (set once), distinct from updated_at (which
-- moves every episode bump) — so the watching-story can say "started 5 days ago".

alter table public.show_progress
  add column if not exists started_at timestamptz not null default now();

-- set_show_progress: stamp started_at on first insert only; never overwrite it
-- on an episode update.
create or replace function public.set_show_progress(
  p_show_id integer, p_season integer, p_episode integer, p_caught_up boolean default false)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into show_progress (user_id, show_id, season, episode, caught_up, started_at, updated_at)
  values (auth.uid(), p_show_id, p_season, p_episode, p_caught_up, now(), now())
  on conflict (user_id, show_id) do update
    set season = excluded.season, episode = excluded.episode,
        caught_up = excluded.caught_up, updated_at = now();   -- started_at untouched
  delete from watchlist where user_id = auth.uid() and movie_id = p_show_id;
end $$;
revoke all on function public.set_show_progress(integer, integer, integer, boolean) from public, anon;
grant execute on function public.set_show_progress(integer, integer, integer, boolean) to authenticated;

-- friends_watching now also returns started_at (shape change → drop+recreate).
drop function if exists public.friends_watching();
create or replace function public.friends_watching()
returns table(user_id uuid, username text, display_name text, avatar_url text,
              show_id integer, title text, poster_path text,
              season integer, episode integer, caught_up boolean,
              started_at timestamptz, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.user_id, p.username, p.display_name, p.avatar_url,
         sp.show_id, m.title, m.poster_path, sp.season, sp.episode, sp.caught_up,
         sp.started_at, sp.updated_at
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
