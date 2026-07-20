-- Mirrors prod migration `must_deliver_push_kinds_and_import_watchlist_clamp`.
--
-- 1) notify_push: exempt must-deliver kinds from the global 5/hr-15/day push
--    cap. Ticket on-sale alerts (watchlist_showing), watch invites/matches,
--    and direct recs are one-shot, time-critical notifications — the cap was
--    silently (and permanently) starving them whenever social activity had
--    already spent the budget. Exempt kinds also stop COUNTING toward the
--    budget, so a ticket alert can't crowd out ordinary notifications either.
--
-- 2) import_watchlist: re-apply the 0044 media_kind clamp (one odd value
--    rolled back a whole 400-title batch) and skip malformed rows
--    (non-numeric tmdb_id / empty title) instead of letting a cast error
--    abort the batch.

create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_exempt constant text[] := array['watchlist_showing', 'watch_invite',
                                    'watch_match', 'direct_rec'];
begin
  if not (new.kind = any(v_exempt)) then
    if (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.id != new.id
          and not (n.kind = any(v_exempt))
          and n.created_at > now() - interval '1 hour') >= 5
    or (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.id != new.id
          and not (n.kind = any(v_exempt))
          and n.created_at > now() - interval '24 hours') >= 15
    then
      return new;
    end if;
  end if;
  perform net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/send-push',
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
exception when others then
  return new;
end $$;

create or replace function public.import_watchlist(p_items jsonb)
returns integer
language plpgsql security definer set search_path = public as $$
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
    if (item->>'tmdb_id') !~ '^-?[0-9]+$' or coalesce(item->>'title', '') = '' then
      continue;   -- malformed row: skip, don't abort the batch
    end if;
    v_movie := (item->>'tmdb_id')::int;

    insert into movies (tmdb_id, media_kind, title, release_year, poster_path, genres, cached_at)
    values (v_movie,
            case when item->>'media_kind' in ('movie', 'tv')
                 then item->>'media_kind' else 'movie' end,
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
