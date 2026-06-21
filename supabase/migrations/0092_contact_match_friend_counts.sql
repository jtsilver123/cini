-- Add a "friends on Cini" count (followers) to the contact-match RPCs so the
-- invite sheet can show social proof next to people you already know who are on
-- Cini ("Maddy · 23 friends on Cini"). Return signature changes, so drop first.

drop function if exists public.members_from_phones(text[]);
create function public.members_from_phones(p_phones text[])
returns table (id uuid, username text, display_name text, avatar_url text,
               match_pct double precision, watched integer, friends_count bigint)
language sql security definer set search_path = public stable as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         null::double precision as match_pct,
         coalesce((select count(*)::int from rankings r where r.user_id = p.id), 0) as watched,
         (select count(*) from follows f where f.following_id = p.id) as friends_count
  from user_phones up
  join profiles p on p.id = up.user_id
  where up.phone_key = any (select public.phone_key(x) from unnest(p_phones) x)
    and p.id <> auth.uid()
    and not exists (select 1 from blocks b
                    where (b.blocker_id = auth.uid() and b.blocked_id = p.id)
                       or (b.blocker_id = p.id and b.blocked_id = auth.uid()));
$$;
revoke all on function public.members_from_phones(text[]) from public, anon;
grant execute on function public.members_from_phones(text[]) to authenticated;

drop function if exists public.members_from_emails(text[]);
create function public.members_from_emails(p_emails text[])
returns table(id uuid, username text, display_name text, avatar_url text,
              friends_count bigint)
language sql stable security definer set search_path to 'public' as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         (select count(*) from follows f where f.following_id = p.id) as friends_count
  from auth.users u
  join profiles p on p.id = u.id
  where lower(u.email) in (select lower(e) from unnest(p_emails) e)
    and p.id <> auth.uid()
    and not_blocked(p.id)
  limit 100;
$$;
revoke execute on function public.members_from_emails(text[]) from public, anon;
grant execute on function public.members_from_emails(text[]) to authenticated;
