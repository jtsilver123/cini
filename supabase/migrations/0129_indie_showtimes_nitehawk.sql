-- Mirrors prod migration `indie_showtimes_nitehawk`.
--
-- NYC venue audit follow-up: Nitehawk publishes ~10 days of showtimes on
-- its own site while its Gracenote feed carries only ~2 — add both
-- locations to the supplemental fetcher. Venue names match Gracenote's
-- EXACTLY so the app's showtimes sheet merges (not duplicates) the two
-- feeds for near-term days.

insert into public.supplemental_venues (id, name, metro, zip) values
  ('nitehawk-wb', 'Nitehawk Cinema Williamsburg', 'nyc', '11249'),
  ('nitehawk-pp', 'Nitehawk Prospect Park', 'nyc', '11215')
on conflict (id) do update
  set name = excluded.name, metro = excluded.metro, zip = excluded.zip;
