-- 0119_defer_join_notifications_until_profile_complete.sql
-- "I got a notification with a crazy username instead of their crafted one."
--
-- Signup creates a PLACEHOLDER profile (username 'user_<8 hex>', empty
-- display name); onboarding fills in the real name + chosen handle a minute
-- later. But identity-bearing "joined" notifications could fire in that gap
-- (an invite deep link redeems the moment auth exists), so the push read
-- "@user_80c93ba8 joined Cini from your invite" — and a push can't be
-- edited after the fact.
--
-- Fix: while the actor's profile is still a placeholder, the join-class
-- notifications (invite_joined / new_follower / contact_joined) are NOT
-- inserted. The moment the profile becomes real (onboarding's profile
-- save), a trigger sends the deferred ones — now carrying the crafted
-- name. Accounts that never finish onboarding never notify (ghosts
-- shouldn't page anyone).

-- A signup-shaped profile that hasn't been through onboarding yet.
create or replace function public.profile_is_placeholder(p_id uuid)
returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select display_name = '' and username ~ '^user_[0-9a-f]{8}$'
     from profiles where id = p_id),
    false);
$$;
revoke all on function public.profile_is_placeholder(uuid) from public, anon, authenticated;

-- 1) redeem_invite_from: create follows + referral as before, but hold the
--    notification while the joiner is still a placeholder.
create or replace function public.redeem_invite_from(p_username text)
returns boolean language plpgsql security definer set search_path = public as $$
declare
  v_inviter uuid;
  v_is_new boolean;
  v_created boolean := false;
begin
  if auth.uid() is null then return false; end if;
  select id into v_inviter from profiles
    where lower(username) = lower(trim(both '@' from trim(p_username)));
  if v_inviter is null or v_inviter = auth.uid() then return false; end if;

  -- Always follow each other (works for an existing user tapping a link too).
  insert into follows (follower_id, following_id)
    values (auth.uid(), v_inviter) on conflict do nothing;
  insert into follows (follower_id, following_id)
    values (v_inviter, auth.uid()) on conflict do nothing;

  -- Only a genuinely NEW account earns the inviter a referral credit — this
  -- prevents farming credits by asking existing friends to tap your link.
  select (created_at > now() - interval '24 hours') into v_is_new
    from profiles where id = auth.uid();

  if coalesce(v_is_new, false) then
    insert into referrals (referrer_id, referred_id)
      values (v_inviter, auth.uid())
      on conflict do nothing
      returning true into v_created;
    -- Notify the inviter only the first time this friend joins — and only
    -- once the joiner has a real name to show. A placeholder profile means
    -- onboarding is mid-flight; the completion trigger below sends it.
    if coalesce(v_created, false) and not public.profile_is_placeholder(auth.uid()) then
      insert into notifications (recipient_id, actor_id, kind)
        values (v_inviter, auth.uid(), 'invite_joined');
    end if;
  end if;

  return true;
end $$;

-- 2) notify_on_follow: hold "started following you" while the follower is a
--    placeholder (keeps the existing founder skip).
create or replace function public.notify_on_follow()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    if new.following_id <> 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid
       and not public.profile_is_placeholder(new.follower_id) then
        insert into notifications (recipient_id, actor_id, kind)
        values (new.following_id, new.follower_id, 'new_follower');
    end if;
    return new;
end $function$;

-- 3) notify_contact_joined: same hold (the completion trigger backfills).
create or replace function public.notify_contact_joined()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    if not public.profile_is_placeholder(new.user_id) then
        insert into notifications (recipient_id, actor_id, kind)
        select cp.owner_id, new.user_id, 'contact_joined'
        from contact_phone_hashes cp
        where cp.phone_hash = encode(sha256(convert_to(new.phone_key, 'UTF8')), 'hex')
          and cp.owner_id <> new.user_id;
    end if;
    return new;
end $function$;

-- 4) The completion trigger: the first time a placeholder profile becomes
--    real, send everything that was held — now with the crafted identity.
create or replace function public.notify_deferred_joins()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    -- Deferred "joined from your invite" (referral recorded during signup).
    insert into notifications (recipient_id, actor_id, kind)
    select r.referrer_id, new.id, 'invite_joined'
    from referrals r
    where r.referred_id = new.id
      and not exists (select 1 from notifications n
                      where n.recipient_id = r.referrer_id
                        and n.actor_id = new.id and n.kind = 'invite_joined');

    -- Deferred "started following you" for non-founder follows made
    -- while the profile was a placeholder.
    insert into notifications (recipient_id, actor_id, kind)
    select f.following_id, new.id, 'new_follower'
    from follows f
    where f.follower_id = new.id
      and f.following_id <> 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid
      and not exists (select 1 from notifications n
                      where n.recipient_id = f.following_id
                        and n.actor_id = new.id and n.kind = 'new_follower');

    -- Deferred "a contact joined" for a phone saved while placeholder.
    insert into notifications (recipient_id, actor_id, kind)
    select cp.owner_id, new.id, 'contact_joined'
    from user_phones up
    join contact_phone_hashes cp
      on cp.phone_hash = encode(sha256(convert_to(up.phone_key, 'UTF8')), 'hex')
    where up.user_id = new.id
      and cp.owner_id <> new.id
      and not exists (select 1 from notifications n
                      where n.recipient_id = cp.owner_id
                        and n.actor_id = new.id and n.kind = 'contact_joined');
    return new;
end $$;

drop trigger if exists trg_profile_completed on public.profiles;
create trigger trg_profile_completed
    after update on public.profiles
    for each row
    when (old.display_name = '' and old.username ~ '^user_[0-9a-f]{8}$'
          and not (new.display_name = '' and new.username ~ '^user_[0-9a-f]{8}$'))
    execute function public.notify_deferred_joins();
