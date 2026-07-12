-- 0118_viewing_prefs.sql
-- Viewing preferences (Settings → Your app → Viewing preferences):
--   streaming_services — the services the user subscribes to ("Netflix",
--     "Max", …, canonical names matching the app's provider filter list).
--     Tonight's Pick leads with a service the user already has, and
--     Where to Watch sorts their services first.
--   screen_formats — preferred theater screens ("IMAX", "Dolby", …).
--     The showtimes sheet opens pre-filtered to a preferred screen when
--     one is actually playing.
-- Owner-only table (like user_locations) — subscriptions are nobody
-- else's business, so nothing lands on the world-readable profiles row.

create table if not exists public.user_prefs (
    user_id            uuid primary key references public.profiles(id) on delete cascade,
    streaming_services text[] not null default '{}',
    screen_formats     text[] not null default '{}',
    updated_at         timestamptz not null default now()
);

alter table public.user_prefs enable row level security;

create policy "own prefs only" on public.user_prefs
    for all to authenticated
    using (user_id = auth.uid()) with check (user_id = auth.uid());
