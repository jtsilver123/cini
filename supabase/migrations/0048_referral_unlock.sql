-- Referral tracking for the unlock mechanic: gate features behind inviting
-- friends who join. redeem_invite_from already created a mutual follow + an
-- invite_joined notification; now it also records a DURABLE referral row
-- (notifications can be cleared, so they can't be the source of truth).

create table if not exists public.referrals (
  referrer_id uuid not null references public.profiles(id) on delete cascade,
  referred_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (referrer_id, referred_id)
);

alter table public.referrals enable row level security;

-- A user can see the referrals they made (drives their unlock credits).
create policy "referrals_select_own" on public.referrals
  for select to authenticated using (referrer_id = auth.uid());

-- Backfill from existing invite_joined notifications.
insert into public.referrals (referrer_id, referred_id)
  select recipient_id, actor_id from public.notifications
   where kind = 'invite_joined'
  on conflict do nothing;

-- redeem_invite_from now also records a durable referral.
create or replace function public.redeem_invite_from(p_username text)
returns boolean language plpgsql security definer set search_path = public as $$
declare v_inviter uuid;
begin
  if auth.uid() is null then return false; end if;
  select id into v_inviter from profiles
    where lower(username) = lower(trim(both '@' from trim(p_username)));
  if v_inviter is null or v_inviter = auth.uid() then return false; end if;
  insert into follows (follower_id, following_id)
    values (auth.uid(), v_inviter) on conflict do nothing;
  insert into follows (follower_id, following_id)
    values (v_inviter, auth.uid()) on conflict do nothing;
  insert into referrals (referrer_id, referred_id)
    values (v_inviter, auth.uid()) on conflict do nothing;
  insert into notifications (recipient_id, actor_id, kind)
    values (v_inviter, auth.uid(), 'invite_joined');
  return true;
end $$;

-- How many friends this user has brought to Cini (= unlock credits).
create or replace function public.referral_count()
returns integer language sql security definer set search_path = public stable as $$
  select count(*)::int from referrals where referrer_id = auth.uid();
$$;

revoke all on function public.referral_count() from public, anon;
grant execute on function public.referral_count() to authenticated;
