-- Harden the referral credit: only a genuinely NEW account earns the inviter
-- a credit, and the inviter is notified only the first time. Without this,
-- credits could be farmed by asking EXISTING friends to tap your invite link,
-- and re-tapping spammed the inviter with "joined" notifications.

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
    -- Notify the inviter only the first time this friend joins (no re-tap spam).
    if coalesce(v_created, false) then
      insert into notifications (recipient_id, actor_id, kind)
        values (v_inviter, auth.uid(), 'invite_joined');
    end if;
  end if;

  return true;
end $$;
