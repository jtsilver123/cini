-- How the user watched it: at home or in a theater.
-- Replaces the labels row in the log flow's details card.
alter table public.rankings
  add column if not exists watched_where text
  check (watched_where in ('home', 'theater'));
