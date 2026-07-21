-- Mirrors prod migration `indie_showtimes`.
--
-- Supplemental showtimes for independent theaters. Verified live: Gracenote
-- carries NYC's indie houses but their feeds only extend ~3 days out
-- (chains publish ~2 weeks), and some institutions never syndicate at all.
-- A 6-hourly edge function (indie-showtimes) reads each venue's PUBLIC
-- calendar directly — the same horizon their own box office sells — and
-- normalizes into supplemental_showtimes. The app merges these rows into
-- the theater calendar and the showtimes sheet, and showtime-alerts
-- matches them for ticket alerts, so one-off repertory screenings (e.g.
-- Basic Instinct at Metrograph) appear as soon as tickets exist.
--
-- v1 venues (metro 'nyc'): Metrograph, Film Forum, IFC Center, Anthology
-- Film Archives. Cloudflare-walled institutions (Film at Lincoln Center,
-- MoMA, MoMI) still need a licensed source.

create table if not exists public.supplemental_venues (
  id text primary key,
  name text not null,
  metro text not null,
  zip text not null
);
alter table public.supplemental_venues enable row level security;
drop policy if exists supplemental_venues_read on public.supplemental_venues;
create policy supplemental_venues_read on public.supplemental_venues
  for select to anon, authenticated using (true);

create table if not exists public.supplemental_showtimes (
  venue_id text not null references public.supplemental_venues(id) on delete cascade,
  title text not null,
  release_year integer,
  format text,
  -- Venue-local 'YYYY-MM-DDTHH:MM', matching Gracenote's dateTime shape so
  -- the app parses both identically.
  starts_at text not null,
  ticket_url text,
  fetched_at timestamptz not null default now(),
  primary key (venue_id, title, starts_at)
);
create index if not exists supplemental_showtimes_day_idx
  on public.supplemental_showtimes (starts_at);
alter table public.supplemental_showtimes enable row level security;
drop policy if exists supplemental_showtimes_read on public.supplemental_showtimes;
create policy supplemental_showtimes_read on public.supplemental_showtimes
  for select to anon, authenticated using (true);
-- Writes: service role only (the fetcher).

insert into public.supplemental_venues (id, name, metro, zip) values
  ('metrograph', 'Metrograph', 'nyc', '10002'),
  ('filmforum', 'Film Forum', 'nyc', '10014'),
  ('ifc', 'IFC Center', 'nyc', '10014'),
  ('anthology', 'Anthology Film Archives', 'nyc', '10003')
on conflict (id) do update
  set name = excluded.name, metro = excluded.metro, zip = excluded.zip;

-- One flat read for the app: every upcoming supplemental showing in a metro.
create or replace function public.supplemental_showings(p_metro text)
returns table(venue text, venue_zip text, title text, release_year integer,
              format text, starts_at text, ticket_url text)
language sql stable security definer set search_path = public as $$
  select v.name, v.zip, s.title, s.release_year, s.format, s.starts_at, s.ticket_url
  from supplemental_showtimes s
  join supplemental_venues v on v.id = s.venue_id
  where v.metro = p_metro
    and s.starts_at >= to_char(now() at time zone 'America/New_York'
                               - interval '1 day', 'YYYY-MM-DD')
  order by s.starts_at;
$$;
revoke all on function public.supplemental_showings(text) from public;
grant execute on function public.supplemental_showings(text) to anon, authenticated;

-- Refresh every 6 hours, offset from the other crons.
select cron.schedule('indie-showtimes-6h', '35 */6 * * *', $$
  select net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/indie-showtimes',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  $$);
