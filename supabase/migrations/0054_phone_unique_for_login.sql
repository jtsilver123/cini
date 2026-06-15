-- Phone becomes a login identifier, so it must map to exactly one account.
create unique index if not exists user_phones_key_unique on public.user_phones (phone_key);

-- set_phone now returns whether it saved: false if the number is already on
-- another account (so signup/onboarding can show a friendly message) or invalid.
drop function if exists public.set_phone(text);
create function public.set_phone(p_phone text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_key text;
begin
  if auth.uid() is null then return false; end if;
  v_key := public.phone_key(p_phone);
  if length(v_key) < 10 then
    delete from user_phones where user_id = auth.uid();
    return true;   -- cleared / no number
  end if;
  if exists (select 1 from user_phones where phone_key = v_key and user_id <> auth.uid()) then
    return false;  -- taken by someone else
  end if;
  insert into user_phones (user_id, phone, phone_key)
    values (auth.uid(), trim(p_phone), v_key)
    on conflict (user_id) do update set phone = excluded.phone, phone_key = excluded.phone_key;
  return true;
end $$;
revoke all on function public.set_phone(text) from public, anon;
grant execute on function public.set_phone(text) to authenticated;

-- Resolve a phone to its account's user id (service-role only; used by the
-- phone-login edge function — never exposed to clients, so no email leak).
create or replace function public.user_id_for_phone(p_phone text)
returns uuid language sql security definer set search_path = public stable as $$
  select user_id from user_phones where phone_key = public.phone_key(p_phone) limit 1;
$$;
revoke all on function public.user_id_for_phone(text) from public, anon, authenticated;
