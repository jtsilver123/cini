-- Proactive "did you watch it? rank it" nudges. One row per (user, title)
-- ever; the daily availability-alerts cron (v3) sends at most one per
-- user per run and is rate-limited to one per ~3 days, so it never nags.
-- Service-role only — the cron writes; nothing client-side reads it.
create table public.rate_nudges (
    user_id uuid not null references public.profiles(id) on delete cascade,
    movie_id integer not null,
    created_at timestamptz not null default now(),
    primary key (user_id, movie_id)
);
alter table public.rate_nudges enable row level security;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array['like', 'comment', 'new_follower',
                             'friend_ranked_watchlist_movie', 'direct_rec',
                             'invite_joined', 'watchlist_showing',
                             'rec_request', 'streaming_now',
                             'season_premiere', 'rate_nudge']));
