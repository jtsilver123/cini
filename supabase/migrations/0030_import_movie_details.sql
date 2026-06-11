-- Letterboxd imports carry reviews and watch dates; landing them one
-- title at a time would be hundreds of round trips. One call takes the
-- whole batch: caches the movie stub (notes/watches FK onto movies),
-- inserts the review as a public note (never clobbering an in-app edit),
-- and adds diary rows (skipping exact duplicates on re-import).
create or replace function public.import_movie_details(p_items jsonb)
returns int
language plpgsql security definer
set search_path to 'public'
as $$
declare
  v_user uuid := auth.uid();
  item jsonb;
  v_movie int;
  v_count int := 0;
begin
  if v_user is null then raise exception 'not authenticated'; end if;
  if jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) > 1000 then
    raise exception 'bad payload';
  end if;

  for item in select * from jsonb_array_elements(p_items) loop
    v_movie := (item->>'tmdb_id')::int;

    insert into movies (tmdb_id, media_kind, title, release_year, poster_path, genres, cached_at)
    values (v_movie,
            coalesce(item->>'media_kind', 'movie'),
            item->>'title',
            (item->>'release_year')::smallint,
            item->>'poster_path',
            coalesce((select array_agg(g) from jsonb_array_elements_text(item->'genres') g), '{}'),
            now())
    on conflict (tmdb_id) do nothing;

    if coalesce(item->>'review', '') <> '' then
      insert into notes (user_id, movie_id, body, is_private)
      values (v_user, v_movie, left(item->>'review', 5000), false)
      on conflict (user_id, movie_id, is_private) do nothing;
    end if;

    if (item->>'watched_on') ~ '^\d{4}-\d{2}-\d{2}$' then
      insert into watches (user_id, movie_id, watched_on)
      select v_user, v_movie, (item->>'watched_on')::date
      where not exists (
        select 1 from watches w
        where w.user_id = v_user and w.movie_id = v_movie
          and w.watched_on = (item->>'watched_on')::date);
    end if;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke execute on function public.import_movie_details(jsonb) from public, anon;
grant execute on function public.import_movie_details(jsonb) to authenticated;
