-- Catch a duplicate phone number on the signup phone step (before the account
-- exists), instead of only after creating it. Phone is collected while the user
-- is still anonymous, so this must be callable by anon. It returns only a
-- boolean — no account details — and reuses the same normalization as set_phone.
create or replace function public.phone_available(p_phone text)
returns boolean language plpgsql security definer set search_path = public stable as $$
declare v_key text;
begin
  v_key := public.phone_key(p_phone);
  if length(v_key) < 10 then return false; end if;   -- not a usable number
  return not exists (select 1 from user_phones where phone_key = v_key);
end $$;
revoke all on function public.phone_available(text) from public;
grant execute on function public.phone_available(text) to anon, authenticated;
