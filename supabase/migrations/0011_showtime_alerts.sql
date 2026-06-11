-- Watchlist showtime alerts (mirrors prod migration `showtime_alerts`).
-- Daily cron -> showtime-alerts edge function: ONE Gracenote call per
-- distinct home_zip, fuzzy-matched against watchlists, delivered through
-- the notifications -> push pipeline, once per (user, movie).

alter table public.profiles
  add column if not exists home_zip text
  check (home_zip is null or home_zip ~ '^[0-9]{5}$');

create table public.showtime_notices (
  user_id uuid not null references auth.users(id) on delete cascade,
  movie_id integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, movie_id)
);
alter table public.showtime_notices enable row level security;

create or replace function public.get_apns_secrets()
returns table (name text, secret text)
language sql security definer set search_path = '' as $$
  select name, decrypted_secret
  from vault.decrypted_secrets
  where name in ('APNS_KEY_P8', 'APNS_KEY_ID', 'APNS_TEAM_ID', 'GRACENOTE_API_KEY');
$$;

select cron.schedule(
  'showtime-alerts-daily',
  '10 16 * * *',
  $$
  select net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/showtime-alerts',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  $$
);
