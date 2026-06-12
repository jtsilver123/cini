-- Constraint hygiene from the hidden-assumption audit: allow only values
-- something actually writes. Phantom values in CHECKs are how the dead
-- Documentaries/Anime categories went unnoticed — the schema advertised
-- kinds nothing produced.
alter table public.movies drop constraint movies_media_kind_check;
alter table public.movies add constraint movies_media_kind_check
  check (media_kind in ('movie', 'tv'));

alter table public.feed_events drop constraint feed_events_event_type_check;
alter table public.feed_events add constraint feed_events_event_type_check
  check (event_type in ('ranked', 'watchlisted', 'noted'));
