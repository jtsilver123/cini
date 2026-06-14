-- 0044: security hardening from the full end-to-end audit.
--   1. Move home_zip (location PII) off the world-readable profiles table.
--   2. Pin rescore_bucket's search_path.
--   3. Scope the avatars SELECT policy to the owner (no bucket listing).
--   4. Clamp import_movie_details media_kind so one bad row can't abort a batch.

-- 1) home_zip was on `profiles`, whose SELECT policy is `using (true)` — so any
--    signed-in user could read everyone's 5-digit home ZIP. Move it to an
--    owner-only table; the showtime-alerts cron (service role) reads it there.
create table if not exists public.user_locations (
    user_id    uuid primary key references public.profiles (id) on delete cascade,
    home_zip   text check (home_zip is null or home_zip ~ '^[0-9]{5}$'),
    updated_at timestamptz not null default now()
);
alter table public.user_locations enable row level security;
drop policy if exists user_locations_owner on public.user_locations;
create policy user_locations_owner on public.user_locations
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

-- Carry existing ZIPs over before dropping the column.
insert into public.user_locations (user_id, home_zip)
select id, home_zip from public.profiles where home_zip is not null
on conflict (user_id) do update set home_zip = excluded.home_zip;

-- The app sets its own ZIP through this RPC (no broad table grants needed).
create or replace function public.set_home_zip(p_zip text) returns void
language plpgsql security definer set search_path = public as $$
begin
    if auth.uid() is null then raise exception 'not authenticated'; end if;
    if p_zip is not null and p_zip !~ '^[0-9]{5}$' then
        raise exception 'invalid zip';
    end if;
    insert into public.user_locations (user_id, home_zip)
    values (auth.uid(), p_zip)
    on conflict (user_id) do update set home_zip = excluded.home_zip, updated_at = now();
end $$;

alter table public.profiles drop column if exists home_zip;

-- 2) rescore_bucket lost its search_path pin when 0043 redefined it. Restore it
--    (SECURITY-relevant: an unpinned search_path on a definer-adjacent function).
create or replace function public.rescore_bucket(p_user uuid, p_bucket text, p_media_kind text)
returns void language plpgsql set search_path = public as $$
declare v_hi numeric; v_lo numeric; v_n integer;
begin
    select case p_bucket when 'loved' then 10.0 when 'fine' then 6.6 else 3.3 end,
           case p_bucket when 'loved' then 6.7  when 'fine' then 3.4 else 0.0 end
    into v_hi, v_lo;

    select count(*) into v_n
    from rankings r join movies m on m.tmdb_id = r.movie_id
    where r.user_id = p_user and r.bucket = p_bucket and m.media_kind = p_media_kind;
    if v_n = 0 then return; end if;

    update rankings r set score = round(
        case when v_n = 1 then v_hi
             else v_hi - (v_hi - v_lo) * r.position / (v_n - 1) end, 1)
    from movies m
    where m.tmdb_id = r.movie_id and r.user_id = p_user
      and r.bucket = p_bucket and m.media_kind = p_media_kind;
end $$;

-- 3) The avatars bucket is public (objects served by URL without RLS), so a
--    broad SELECT policy only enabled listing every file (= every user id with
--    an avatar). Scope SELECT to the owner — still satisfies the upload's
--    INSERT...RETURNING, public display is unaffected.
drop policy if exists avatar_select_public on storage.objects;
drop policy if exists avatar_select_own on storage.objects;
create policy avatar_select_own on storage.objects
    for select to authenticated
    using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');

-- 4) A Letterboxd/third-party row with an unexpected media_kind violated the
--    ('movie','tv') CHECK and rolled back the WHOLE import. Clamp it.
create or replace function public.import_movie_details(p_items jsonb)
returns integer language plpgsql security definer set search_path = public as $$
declare
  v_user uuid := auth.uid();
  item jsonb;
  v_movie int;
  v_date text;
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
            case when item->>'media_kind' in ('movie', 'tv') then item->>'media_kind' else 'movie' end,
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

    for v_date in
      select distinct d from (
        select jsonb_array_elements_text(
          case when jsonb_typeof(item->'watched_dates') = 'array'
               then item->'watched_dates' else '[]'::jsonb end) as d
        union
        select item->>'watched_on'
      ) dates
      where d ~ '^\d{4}-\d{2}-\d{2}$'
      limit 100
    loop
      insert into watches (user_id, movie_id, watched_on)
      select v_user, v_movie, v_date::date
      where not exists (
        select 1 from watches w
        where w.user_id = v_user and w.movie_id = v_movie
          and w.watched_on = v_date::date);
    end loop;

    v_count := v_count + 1;
  end loop;
  return v_count;
end $$;
