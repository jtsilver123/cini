-- A list belongs to ONE media type: it holds movies or shows, never
-- both, and appears only under its category in the Lists tab. Existing
-- lists were backfilled to whichever kind dominated their items.
-- Applied to prod as `custom_lists_media_kind`.
alter table public.custom_lists
  add column media_kind text not null default 'movie'
  check (media_kind in ('movie', 'tv'));

update public.custom_lists cl
set media_kind = 'tv'
where (
  select count(*) filter (where m.media_kind = 'tv')
       > count(*) filter (where m.media_kind <> 'tv')
  from custom_list_items i
  join movies m on m.tmdb_id = i.movie_id
  where i.list_id = cl.id
);
