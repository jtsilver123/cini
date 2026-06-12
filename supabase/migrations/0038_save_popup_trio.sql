-- Save-popup trio (Beli parity): notes on bookmarks, per-title streaming
-- alerts, and stealth saves (the last is client-side feed-event removal).
-- Plus season-premiere alerts for ranked shows. Applied to prod as
-- `save_popup_trio`; the TMDB key joined the Vault (not in this file —
-- the repo is public) and pg_cron invokes availability-alerts daily.

alter table public.watchlist add column note text;

create or replace function public.set_watchlist_note(p_movie_id integer, p_note text)
returns void
language sql
security definer
set search_path to 'public'
as $$
    update watchlist
    set note = nullif(trim(p_note), '')
    where user_id = auth.uid() and movie_id = p_movie_id;
$$;
revoke all on function public.set_watchlist_note(integer, text) from public, anon;
grant execute on function public.set_watchlist_note(integer, text) to authenticated;

-- "Tell me when it's streaming": client manages its own rows; the daily
-- availability-alerts function notifies and stamps notified_at.
create table public.streaming_alerts (
    user_id uuid not null references public.profiles(id) on delete cascade,
    movie_id integer not null references public.movies(tmdb_id),
    created_at timestamptz not null default now(),
    notified_at timestamptz,
    primary key (user_id, movie_id)
);
alter table public.streaming_alerts enable row level security;
create policy streaming_alerts_own on public.streaming_alerts
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- One season-premiere notice per (user, show, season) — service-role only.
create table public.season_notices (
    user_id uuid not null references public.profiles(id) on delete cascade,
    movie_id integer not null,
    season integer not null,
    created_at timestamptz not null default now(),
    primary key (user_id, movie_id, season)
);
alter table public.season_notices enable row level security;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array['like', 'comment', 'new_follower',
                             'friend_ranked_watchlist_movie', 'direct_rec',
                             'invite_joined', 'watchlist_showing',
                             'rec_request', 'streaming_now',
                             'season_premiere']));

-- The availability cron needs the TMDB key alongside the other secrets.
create or replace function public.get_apns_secrets()
returns table (name text, secret text)
language sql security definer set search_path = '' as $$
  select name, decrypted_secret
  from vault.decrypted_secrets
  where name in ('APNS_KEY_P8', 'APNS_KEY_ID', 'APNS_TEAM_ID',
                 'GRACENOTE_API_KEY', 'TMDB_API_KEY');
$$;
