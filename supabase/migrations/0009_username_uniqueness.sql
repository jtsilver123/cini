-- Usernames: case-insensitively unique, enforced format, and a live
-- availability check (mirrors prod migration `username_uniqueness`).

create unique index if not exists profiles_username_lower_key
  on public.profiles (lower(username));

alter table public.profiles
  add constraint profiles_username_format
  check (username ~ '^[a-z0-9_]{3,20}$');

create or replace function public.username_available(p_username text)
returns boolean
language sql stable security definer set search_path = public as $$
  select not exists (
    select 1 from profiles
    where lower(username) = lower(p_username)
      and id is distinct from auth.uid()
  );
$$;

revoke all on function public.username_available(text) from public, anon;
grant execute on function public.username_available(text) to authenticated;
