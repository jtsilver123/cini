-- "A contact joined Cini" (Beli-style), least-invasive version.
--
-- We do NOT store readable phone numbers or names for non-users. We store only
-- a SHA-256 hash of each contact's number. A new signup's own number is hashed
-- the same way and matched against those hashes to notify the people who had
-- them in their address book. Hashes are written only when the user explicitly
-- uses "Find friends" (which requires the Contacts permission), and the user
-- can wipe them any time (and they're deleted with the account).

create table if not exists public.contact_phone_hashes (
    owner_id   uuid not null references public.profiles(id) on delete cascade,
    phone_hash text not null,
    created_at timestamptz not null default now(),
    primary key (owner_id, phone_hash)
);
alter table public.contact_phone_hashes enable row level security;

-- Only the owner can touch their own rows; nobody can read anyone else's.
create policy "own contact hashes only" on public.contact_phone_hashes
    for all using (owner_id = auth.uid()) with check (owner_id = auth.uid());

-- Store the caller's contacts as hashes (numbers normalized to 10-digit keys,
-- then SHA-256'd, server-side — raw numbers and names never persist).
create or replace function public.store_contacts(p_phones text[])
returns void
language sql security definer set search_path to 'public'
as $function$
    insert into contact_phone_hashes (owner_id, phone_hash)
    select auth.uid(), encode(sha256(convert_to(k, 'UTF8')), 'hex')
    from (select distinct public.phone_key(p) as k from unnest(p_phones) p) s
    where auth.uid() is not null and length(k) = 10
    on conflict (owner_id, phone_hash) do nothing;
$function$;

-- Wipe the caller's stored contact hashes.
create or replace function public.forget_contacts()
returns void
language sql security definer set search_path to 'public'
as $function$
    delete from contact_phone_hashes where owner_id = auth.uid();
$function$;

-- New notification kind.
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved',
        'saved_your_rank','streak_reminder','contact_joined']));

-- When a new user's number is first stored (signup), notify everyone who had
-- that number's hash in their contacts. INSERT-only, so changing your number
-- later (on-conflict update) doesn't re-notify.
create or replace function public.notify_contact_joined()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    insert into notifications (recipient_id, actor_id, kind)
    select cp.owner_id, new.user_id, 'contact_joined'
    from contact_phone_hashes cp
    where cp.phone_hash = encode(sha256(convert_to(new.phone_key, 'UTF8')), 'hex')
      and cp.owner_id <> new.user_id;
    return new;
end $function$;

drop trigger if exists trg_contact_joined on public.user_phones;
create trigger trg_contact_joined
    after insert on public.user_phones
    for each row execute function public.notify_contact_joined();

revoke all on function public.store_contacts(text[]) from public, anon;
revoke all on function public.forget_contacts() from public, anon;
grant execute on function public.store_contacts(text[]) to authenticated;
grant execute on function public.forget_contacts() to authenticated;
