-- Feature unlocks: each accepted referral is one credit the user spends to
-- unlock a feature of their choice (Beli-style). Whitelisted keys:
--   aggregate_scores · social_links · stealth_mode

create table if not exists public.feature_unlocks (
  user_id uuid not null references public.profiles(id) on delete cascade,
  feature text not null,
  created_at timestamptz not null default now(),
  primary key (user_id, feature)
);

alter table public.feature_unlocks enable row level security;

create policy "feature_unlocks_select_own" on public.feature_unlocks
  for select to authenticated using (user_id = auth.uid());

-- Spend one referral credit (an accepted referral not yet spent) to unlock a
-- feature. Idempotent for an already-unlocked feature; rejects unknown keys.
create or replace function public.unlock_feature(p_feature text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_credits int; v_spent int;
begin
  if auth.uid() is null then return false; end if;
  if p_feature not in ('aggregate_scores','social_links','stealth_mode') then
    return false;
  end if;
  if exists (select 1 from feature_unlocks where user_id = auth.uid() and feature = p_feature) then
    return true;
  end if;
  select count(*) into v_credits from referrals where referrer_id = auth.uid();
  select count(*) into v_spent from feature_unlocks where user_id = auth.uid();
  if v_spent >= v_credits then
    return false;
  end if;
  insert into feature_unlocks (user_id, feature) values (auth.uid(), p_feature)
    on conflict do nothing;
  return true;
end $$;

revoke all on function public.unlock_feature(text) from public, anon;
grant execute on function public.unlock_feature(text) to authenticated;

-- The features this user has unlocked.
create or replace function public.unlocked_features()
returns setof text language sql security definer set search_path = public stable as $$
  select feature from feature_unlocks where user_id = auth.uid();
$$;

revoke all on function public.unlocked_features() from public, anon;
grant execute on function public.unlocked_features() to authenticated;
