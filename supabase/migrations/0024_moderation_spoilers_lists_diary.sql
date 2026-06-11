-- Applied to prod via MCP on 2026-06-11. Four features:
-- 1) blocks + reports (App Store 1.2 UGC moderation) — can_view refuses
--    across a block edge, filtering every feed/wall/list server-side.
-- 2) spoiler flags on notes (movie_public_notes + movie_friend_scores
--    return contains_spoilers).
-- 3) custom lists (custom_lists + custom_list_items).
-- 4) diary (watches: one row per watch, rewatches included).
-- See the applied migration in Supabase for the full SQL; this file
-- mirrors it for version control.

create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
alter table public.blocks enable row level security;
create policy blocks_own on public.blocks
  for all using (blocker_id = auth.uid()) with check (blocker_id = auth.uid());

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  subject_kind text not null check (subject_kind in ('member','note','comment','event')),
  subject_id text not null,
  reason text,
  created_at timestamptz not null default now()
);
alter table public.reports enable row level security;
create policy reports_insert on public.reports
  for insert with check (reporter_id = auth.uid());

create or replace function public.not_blocked(other uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
  select not exists (
    select 1 from blocks b
    where (b.blocker_id = auth.uid() and b.blocked_id = other)
       or (b.blocker_id = other and b.blocked_id = auth.uid()));
$$;

create or replace function public.can_view(owner uuid) returns boolean
language sql stable security definer set search_path to 'public' as $$
    select not_blocked(owner) and (
        owner = auth.uid()
        or exists (select 1 from profiles p where p.id = owner and not p.is_private)
        or exists (select 1 from follows f
                   where f.following_id = owner and f.follower_id = auth.uid()));
$$;

drop policy comments_select on public.comments;
create policy comments_select on public.comments for select using (
  not_blocked(user_id) and exists (
    select 1 from feed_events e where e.id = comments.event_id and can_view(e.user_id)));

alter table public.notes add column contains_spoilers boolean not null default false;
-- movie_public_notes + movie_friend_scores recreated to return
-- contains_spoilers (see prod definitions).

create table public.custom_lists (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 60),
  is_private boolean not null default false,
  created_at timestamptz not null default now()
);
alter table public.custom_lists enable row level security;
create policy custom_lists_own on public.custom_lists
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy custom_lists_select on public.custom_lists
  for select using (user_id = auth.uid() or (not is_private and can_view(user_id)));

create table public.custom_list_items (
  list_id uuid not null references public.custom_lists(id) on delete cascade,
  movie_id integer not null,
  position integer not null default 0,
  created_at timestamptz not null default now(),
  primary key (list_id, movie_id)
);
alter table public.custom_list_items enable row level security;
create policy custom_list_items_own on public.custom_list_items
  for all using (exists (select 1 from custom_lists l where l.id = list_id and l.user_id = auth.uid()))
  with check (exists (select 1 from custom_lists l where l.id = list_id and l.user_id = auth.uid()));
create policy custom_list_items_select on public.custom_list_items
  for select using (exists (
    select 1 from custom_lists l where l.id = list_id
      and (l.user_id = auth.uid() or (not l.is_private and can_view(l.user_id)))));

create table public.watches (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  movie_id integer not null,
  watched_on date not null default current_date,
  watched_where text check (watched_where in ('home', 'theater')),
  created_at timestamptz not null default now()
);
alter table public.watches enable row level security;
create policy watches_own on public.watches
  for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy watches_select on public.watches for select using (can_view(user_id));
create index watches_user_date on public.watches (user_id, watched_on desc);
