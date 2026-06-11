-- The app embeds movies(*) when loading direct recs; PostgREST needs a
-- real FK to resolve the relationship (PGRST200 without it, and the
-- friend-recs inbox silently failed to load).
alter table public.direct_recs
  add constraint direct_recs_movie_id_fkey
  foreign key (movie_id) references public.movies(tmdb_id);
