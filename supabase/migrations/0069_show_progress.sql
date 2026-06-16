-- 0069_show_progress.sql
-- "Currently Watching": let users mark a show they're mid-binge on, with an
-- optional season/episode, so friends can see what everyone's watching right
-- now. Powers the "Friends are watching" shelf and the profile shelf.
--
-- TV shows live in `movies` with NEGATIVE tmdb_id (the app's movie/TV split);
-- show_id follows that convention.

create table if not exists public.show_progress (
  user_id    uuid not null references public.profiles(id) on delete cascade,
  show_id    integer not null references public.movies(tmdb_id),
  season     integer,
  episode    integer,
  updated_at timestamptz not null default now(),
  primary key (user_id, show_id)
);
create index show_progress_recent_idx on public.show_progress (user_id, updated_at desc);
alter table public.show_progress enable row level security;
-- Owner does everything; anyone who can_view the owner can read (the shelf).
create policy show_progress_owner on public.show_progress
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy show_progress_visible on public.show_progress
  for select to authenticated
  using (can_view(user_id));

-- ---- Set / update where I am in a show ----
-- Starting to watch supersedes "want to watch", so it drops the watchlist row.
create or replace function public.set_show_progress(p_show_id integer, p_season integer, p_episode integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  insert into show_progress (user_id, show_id, season, episode, updated_at)
  values (auth.uid(), p_show_id, p_season, p_episode, now())
  on conflict (user_id, show_id) do update
    set season = excluded.season, episode = excluded.episode, updated_at = now();
  delete from watchlist where user_id = auth.uid() and movie_id = p_show_id;
end $$;
revoke all on function public.set_show_progress(integer, integer, integer) from public, anon;
grant execute on function public.set_show_progress(integer, integer, integer) to authenticated;

create or replace function public.clear_show_progress(p_show_id integer)
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  delete from show_progress where user_id = auth.uid() and show_id = p_show_id;
end $$;
revoke all on function public.clear_show_progress(integer) from public, anon;
grant execute on function public.clear_show_progress(integer) to authenticated;

-- ---- Reads ----
-- Friends (you follow, not blocked) currently watching something — the shelf.
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
  where not_blocked_pair(auth.uid(), sp.user_id)
  order by sp.updated_at desc
  limit 30;
$$;
revoke all on function public.friends_watching() from public, anon;
grant execute on function public.friends_watching() to authenticated;

-- A member's current shows (mine for my profile; a friend's if I can_view them).
create or replace function public.watching_for(p_user uuid)
returns table(show_id integer, title text, poster_path text,
              season integer, episode integer, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.show_id, m.title, m.poster_path, sp.season, sp.episode, sp.updated_at
  from show_progress sp
  join movies m on m.tmdb_id = sp.show_id
  where sp.user_id = p_user
    and (p_user = auth.uid() or can_view(p_user))
  order by sp.updated_at desc;
$$;
revoke all on function public.watching_for(uuid) from public, anon;
grant execute on function public.watching_for(uuid) to authenticated;

-- ---- Ranking a show = you finished it → clear the "watching" marker ----
create or replace function public.clear_progress_on_rank()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  delete from show_progress where user_id = new.user_id and show_id = new.movie_id;
  return new;
end $$;
drop trigger if exists trg_clear_progress_on_rank on public.rankings;
create trigger trg_clear_progress_on_rank
  after insert on public.rankings
  for each row execute function public.clear_progress_on_rank();
