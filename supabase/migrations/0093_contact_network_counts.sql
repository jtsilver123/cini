-- Beli-style "N on Cini know them" for contacts who haven't joined yet.
--
-- We already store a SHA-256 hash of each user's contacts (contact_phone_hashes,
-- migration 0059). For a given phone, the number of DISTINCT owners whose hash
-- set contains it = how many Cini users have that person in their address book —
-- a network-effect signal that surfaces (and sorts) the best people to invite,
-- without revealing any identities (aggregate count only).

-- Lookups here are by phone_hash alone; the table PK leads with owner_id, so add
-- a hash index for this and the contact-joined trigger.
create index if not exists contact_phone_hashes_hash_idx
    on public.contact_phone_hashes (phone_hash);

create or replace function public.contact_network_counts(p_phones text[])
returns table(phone_key text, known_by bigint)
language sql security definer set search_path = public stable as $$
  select s.k as phone_key,
         count(distinct cph.owner_id) as known_by
  from (select distinct public.phone_key(p) as k from unnest(p_phones) p) s
  join contact_phone_hashes cph
    on cph.phone_hash = encode(sha256(convert_to(s.k, 'UTF8')), 'hex')
   and cph.owner_id <> auth.uid()
  where length(s.k) = 10
  group by s.k;
$$;

revoke all on function public.contact_network_counts(text[]) from public, anon;
grant execute on function public.contact_network_counts(text[]) to authenticated;
