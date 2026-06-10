-- Cini initial schema.
-- Conventions: all tables in public, all user-owned rows keyed to auth.users
-- via profiles.id. Movie metadata is a cache of TMDB, keyed by tmdb_id.

create extension if not exists pg_trgm;

-- ---------------------------------------------------------------------------
-- Profiles
-- ---------------------------------------------------------------------------
create table public.profiles (
    id            uuid primary key references auth.users (id) on delete cascade,
    username      text not null unique check (username ~ '^[a-z0-9_\.]{3,30}$'),
    display_name  text not null default '',
    avatar_url    text,
    school        text,
    grad_year     smallint,
    member_since  timestamptz not null default now(),
    is_private    boolean not null default false,
    streak_weeks  integer not null default 0,
    last_logged_week date,                -- ISO week anchor for streak math
    annual_goal   integer,                -- e.g. 200 movies for the year
    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now()
);

create index profiles_username_trgm on public.profiles using gin (username gin_trgm_ops);
create index profiles_school_idx on public.profiles (school);

-- ---------------------------------------------------------------------------
-- Movies: cached TMDB metadata. Either a movie or a TV season-level entity.
-- v1 ranks TV shows as whole seasons only; media_kind leaves room for more.
-- ---------------------------------------------------------------------------
create table public.movies (
    tmdb_id        integer primary key,
    media_kind     text not null default 'movie'
                   check (media_kind in ('movie', 'tv', 'documentary', 'anime')),
    title          text not null,
    release_year   smallint,
    poster_path    text,
    backdrop_path  text,
    genres         text[] not null default '{}',
    certification  text,                  -- e.g. PG-13, R
    runtime_minutes integer,
    director       text,
    overview       text,
    cached_at      timestamptz not null default now()
);

create index movies_title_trgm on public.movies using gin (title gin_trgm_ops);

-- ---------------------------------------------------------------------------
-- Rankings: one row per (user, movie). Position is bucket-local, 0 = best.
-- Positions and scores are maintained atomically via the rank_insert /
-- rank_remove RPCs in 0003 — clients never write position directly.
-- ---------------------------------------------------------------------------
create table public.rankings (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references public.profiles (id) on delete cascade,
    movie_id    integer not null references public.movies (tmdb_id),
    bucket      text not null check (bucket in ('loved', 'fine', 'disliked')),
    position    integer not null check (position >= 0),
    score       numeric(3, 1) not null check (score >= 0 and score <= 10),
    watch_date  date,
    watched_with uuid[] not null default '{}',   -- tagged friends
    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now(),
    unique (user_id, movie_id)
);

create index rankings_user_bucket_pos on public.rankings (user_id, bucket, position);
create index rankings_movie_idx on public.rankings (movie_id);

-- ---------------------------------------------------------------------------
-- Watchlist
-- ---------------------------------------------------------------------------
create table public.watchlist (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles (id) on delete cascade,
    movie_id   integer not null references public.movies (tmdb_id),
    created_at timestamptz not null default now(),
    unique (user_id, movie_id)
);

create index watchlist_user_idx on public.watchlist (user_id, created_at desc);
create index watchlist_movie_idx on public.watchlist (movie_id);

-- ---------------------------------------------------------------------------
-- Notes: public review text or private personal notes (eye-slash).
-- ---------------------------------------------------------------------------
create table public.notes (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles (id) on delete cascade,
    movie_id   integer not null references public.movies (tmdb_id),
    body       text not null check (char_length(body) <= 5000),
    is_private boolean not null default false,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (user_id, movie_id, is_private)
);

create index notes_movie_idx on public.notes (movie_id) where not is_private;

-- ---------------------------------------------------------------------------
-- Favorite performances (Beli's "Favorite Dishes" → standout actors/scenes)
-- ---------------------------------------------------------------------------
create table public.favorite_performances (
    id             uuid primary key default gen_random_uuid(),
    user_id        uuid not null references public.profiles (id) on delete cascade,
    movie_id       integer not null references public.movies (tmdb_id),
    tmdb_person_id integer not null,
    person_name    text not null,
    profile_path   text,
    character_name text,
    created_at     timestamptz not null default now(),
    unique (user_id, movie_id, tmdb_person_id)
);

create index fav_perf_movie_person on public.favorite_performances (movie_id, tmdb_person_id);

-- ---------------------------------------------------------------------------
-- Labels ("Date Night", "Plane Movie", "Mindblower") + join table
-- ---------------------------------------------------------------------------
create table public.labels (
    id         uuid primary key default gen_random_uuid(),
    owner_id   uuid references public.profiles (id) on delete cascade, -- null = built-in
    name       text not null check (char_length(name) between 1 and 40),
    unique (owner_id, name)
);

create table public.ranking_labels (
    ranking_id uuid not null references public.rankings (id) on delete cascade,
    label_id   uuid not null references public.labels (id) on delete cascade,
    primary key (ranking_id, label_id)
);

-- ---------------------------------------------------------------------------
-- Social graph
-- ---------------------------------------------------------------------------
create table public.follows (
    follower_id  uuid not null references public.profiles (id) on delete cascade,
    following_id uuid not null references public.profiles (id) on delete cascade,
    created_at   timestamptz not null default now(),
    primary key (follower_id, following_id),
    check (follower_id <> following_id)
);

create index follows_following_idx on public.follows (following_id);

-- ---------------------------------------------------------------------------
-- Feed events. One row per activity; fan-out happens at read time via the
-- follow graph (fine at v1 scale; leaves room for a fan-out-on-write table).
-- ---------------------------------------------------------------------------
create table public.feed_events (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles (id) on delete cascade,
    event_type text not null check (event_type in
        ('ranked', 'watchlisted', 'noted', 'challenge_milestone', 'streak_milestone', 'asked_for_recs')),
    movie_id   integer references public.movies (tmdb_id),
    payload    jsonb not null default '{}',   -- score, milestone count, prompt text…
    created_at timestamptz not null default now()
);

create index feed_events_user_time on public.feed_events (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Likes & comments (on feed events)
-- ---------------------------------------------------------------------------
create table public.likes (
    user_id    uuid not null references public.profiles (id) on delete cascade,
    event_id   uuid not null references public.feed_events (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, event_id)
);

create table public.comments (
    id         uuid primary key default gen_random_uuid(),
    user_id    uuid not null references public.profiles (id) on delete cascade,
    event_id   uuid not null references public.feed_events (id) on delete cascade,
    body       text not null check (char_length(body) <= 2000),
    created_at timestamptz not null default now()
);

create index comments_event_idx on public.comments (event_id, created_at);

-- ---------------------------------------------------------------------------
-- Notifications
-- ---------------------------------------------------------------------------
create table public.notifications (
    id           uuid primary key default gen_random_uuid(),
    recipient_id uuid not null references public.profiles (id) on delete cascade,
    actor_id     uuid references public.profiles (id) on delete cascade,
    kind         text not null check (kind in
        ('like', 'comment', 'new_follower', 'friend_ranked_watchlist_movie')),
    event_id     uuid references public.feed_events (id) on delete cascade,
    movie_id     integer references public.movies (tmdb_id),
    read_at      timestamptz,
    created_at   timestamptz not null default now()
);

create index notifications_recipient_idx on public.notifications (recipient_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Taste match cache (rank-order correlation, refreshed nightly)
-- ---------------------------------------------------------------------------
create table public.taste_matches (
    user_a      uuid not null references public.profiles (id) on delete cascade,
    user_b      uuid not null references public.profiles (id) on delete cascade,
    pct         numeric(5, 2) not null,
    sample_size integer not null default 0,    -- commonly ranked titles
    computed_at timestamptz not null default now(),
    primary key (user_a, user_b),
    check (user_a < user_b)                    -- store each pair once
);

-- ---------------------------------------------------------------------------
-- Invites / referrals
-- ---------------------------------------------------------------------------
create table public.invites (
    code        text primary key,
    inviter_id  uuid not null references public.profiles (id) on delete cascade,
    invitee_id  uuid references public.profiles (id),
    created_at  timestamptz not null default now(),
    redeemed_at timestamptz
);

-- updated_at maintenance
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$
begin
    new.updated_at = now();
    return new;
end $$;

create trigger profiles_touch before update on public.profiles
    for each row execute function public.touch_updated_at();
create trigger rankings_touch before update on public.rankings
    for each row execute function public.touch_updated_at();
create trigger notes_touch before update on public.notes
    for each row execute function public.touch_updated_at();
