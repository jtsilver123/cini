-- A Letterboxd watchlist lands in ONE call per batch instead of two round
-- trips per title (movie cache + watchlist_toggle), and QUIETLY — a mass
-- import must not flood followers' feeds with hundreds of 'watchlisted'
-- events (the per-title toggle emits one each).
create or replace function public.import_watchlist(p_items jsonb)
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

    insert into watchlist (user_id, movie_id)
    values (v_user, v_movie)
    on conflict (user_id, movie_id) do nothing;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;

revoke execute on function public.import_watchlist(jsonb) from public, anon;
grant execute on function public.import_watchlist(jsonb) to authenticated;
