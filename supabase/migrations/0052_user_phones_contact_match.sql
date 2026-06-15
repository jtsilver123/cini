-- Optional, unverified phone number (Beli-style) for contact matching.
-- Stored in its own owner-only table (never world-readable on profiles),
-- with a normalized match key (digits, last 10 — US-centric for launch).

create table if not exists public.user_phones (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  phone text not null,
  phone_key text not null,
  created_at timestamptz not null default now()
);
create index if not exists user_phones_key_idx on public.user_phones (phone_key);

alter table public.user_phones enable row level security;
create policy "user_phones_select_own" on public.user_phones
  for select to authenticated using (user_id = auth.uid());

create or replace function public.phone_key(p text)
returns text language sql immutable as $$
  select right(regexp_replace(coalesce(p, ''), '\D', '', 'g'), 10);
$$;

-- Save / update the caller's phone (no SMS verification — consent-based).
create or replace function public.set_phone(p_phone text)
returns void language plpgsql security definer set search_path = public as $$
declare v_key text;
begin
  if auth.uid() is null then return; end if;
  v_key := public.phone_key(p_phone);
  if length(v_key) < 10 then
    delete from user_phones where user_id = auth.uid();
    return;
  end if;
  insert into user_phones (user_id, phone, phone_key)
    values (auth.uid(), trim(p_phone), v_key)
    on conflict (user_id) do update set phone = excluded.phone, phone_key = excluded.phone_key;
end $$;

revoke all on function public.set_phone(text) from public, anon;
grant execute on function public.set_phone(text) to authenticated;

create or replace function public.my_phone()
returns text language sql security definer set search_path = public stable as $$
  select phone from user_phones where user_id = auth.uid();
$$;
revoke all on function public.my_phone() from public, anon;
grant execute on function public.my_phone() to authenticated;

-- Which of these phone numbers belong to Cini members (mirror of
-- members_from_emails). Excludes self and anyone you've blocked.
create or replace function public.members_from_phones(p_phones text[])
returns table (id uuid, username text, display_name text, avatar_url text,
               match_pct double precision, watched integer)
language sql security definer set search_path = public stable as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         null::double precision as match_pct,
         coalesce((select count(*)::int from rankings r where r.user_id = p.id), 0) as watched
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
