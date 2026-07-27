-- Crews, v1 (mirrors prod migration `crews`): a small named group of friends
-- with a shared "what should WE watch" view. The overlap of members' Want to
-- Watch lists IS the ballot — every bookmark is a vote, no separate voting
-- machinery. Small groups retain better than follow-feeds: the group chat,
-- not the timeline, is what keeps people coming back.
--
-- Shape: crews (name, owner) + crew_members roster. All writes go through
-- SECURITY DEFINER RPCs (create / add member / leave); reads are RLS-gated
-- to members via a definer helper (same pattern as watch plans — a naive
-- member policy would recurse). Caps: 8 members per crew, 5 crews per user.
-- Adding someone notifies them ('crew_added', registered in 0130's kind
-- check).

create table if not exists public.crews (
    id uuid primary key default gen_random_uuid(),
    name text not null check (char_length(name) between 1 and 40),
    owner_id uuid not null references public.profiles(id) on delete cascade,
    created_at timestamptz not null default now()
);

create table if not exists public.crew_members (
    crew_id uuid not null references public.crews(id) on delete cascade,
    user_id uuid not null references public.profiles(id) on delete cascade,
    added_by uuid references public.profiles(id) on delete set null,
    created_at timestamptz not null default now(),
    primary key (crew_id, user_id)
);

create index if not exists crew_members_user_idx on public.crew_members (user_id);

alter table public.crews enable row level security;
alter table public.crew_members enable row level security;

-- Definer helper so the member policies can't recurse into themselves.
create or replace function public.is_crew_member(p_crew uuid)
returns boolean
language sql security definer set search_path = public
stable as $$
    select exists (select 1 from crew_members
                   where crew_id = p_crew and user_id = auth.uid());
$$;

revoke all on function public.is_crew_member(uuid) from public, anon;
grant execute on function public.is_crew_member(uuid) to authenticated;

drop policy if exists crews_member_select on public.crews;
create policy crews_member_select on public.crews
    for select to authenticated
    using (public.is_crew_member(id));

drop policy if exists crew_members_member_select on public.crew_members;
create policy crew_members_member_select on public.crew_members
    for select to authenticated
    using (public.is_crew_member(crew_id));

-- ------------------------------------------------------------------ RPCs

create or replace function public.crew_create(p_name text)
returns uuid
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_crew uuid;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if char_length(trim(p_name)) not between 1 and 40 then
        raise exception 'bad name';
    end if;
    if (select count(*) from crew_members where user_id = v_user) >= 5 then
        raise exception 'crew limit';
    end if;
    insert into crews (name, owner_id) values (trim(p_name), v_user)
    returning id into v_crew;
    insert into crew_members (crew_id, user_id, added_by)
    values (v_crew, v_user, v_user);
    return v_crew;
end $$;

revoke all on function public.crew_create(text) from public, anon;
grant execute on function public.crew_create(text) to authenticated;

-- Any member can add a MUTUAL friend (both follow each other) — same trust
-- bar as watch plans. Notifies the new member.
create or replace function public.crew_add_member(p_crew uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_name text;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if not exists (select 1 from crew_members
                   where crew_id = p_crew and user_id = v_user) then
        raise exception 'not a member';
    end if;
    if not exists (select 1 from follows a
                   join follows b on b.follower_id = a.following_id
                                 and b.following_id = a.follower_id
                   where a.follower_id = v_user and a.following_id = p_user) then
        raise exception 'not mutuals';
    end if;
    if exists (select 1 from blocks
               where (blocker_id = p_user and blocked_id = v_user)
                  or (blocker_id = v_user and blocked_id = p_user)) then
        raise exception 'blocked';
    end if;
    if (select count(*) from crew_members where crew_id = p_crew) >= 8 then
        raise exception 'crew full';
    end if;
    if (select count(*) from crew_members where user_id = p_user) >= 5 then
        raise exception 'crew limit';
    end if;
    insert into crew_members (crew_id, user_id, added_by)
    values (p_crew, p_user, v_user)
    on conflict (crew_id, user_id) do nothing;

    select name into v_name from crews where id = p_crew;
    insert into notifications (recipient_id, actor_id, kind, message)
    select p_user, v_user, 'crew_added', v_name
    from profiles p
    where p.id = p_user
      and not ('crew_added' = any(coalesce(p.muted_notification_kinds, '{}')));
end $$;

revoke all on function public.crew_add_member(uuid, uuid) from public, anon;
grant execute on function public.crew_add_member(uuid, uuid) to authenticated;

-- Leaving as the last member deletes the crew; the owner leaving hands the
-- crew to its longest-standing remaining member.
create or replace function public.crew_leave(p_crew uuid)
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_next uuid;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    delete from crew_members where crew_id = p_crew and user_id = v_user;
    if not exists (select 1 from crew_members where crew_id = p_crew) then
        delete from crews where id = p_crew;
    elsif exists (select 1 from crews where id = p_crew and owner_id = v_user) then
        select user_id into v_next from crew_members
        where crew_id = p_crew order by created_at limit 1;
        update crews set owner_id = v_next where id = p_crew;
    end if;
end $$;

revoke all on function public.crew_leave(uuid) from public, anon;
grant execute on function public.crew_leave(uuid) to authenticated;

-- The crew's ballot: titles on 2+ members' Want to Watch lists, strongest
-- overlap first, with who wants each one. (A single member's crew shows
-- their own list so a fresh crew isn't a blank screen.)
create or replace function public.crew_overlap(p_crew uuid)
returns table (
    movie_id integer,
    want_count integer,
    member_usernames text[]
)
language sql security definer set search_path = public
stable as $$
    select w.movie_id,
           count(*)::integer as want_count,
           array_agg(p.username order by w.created_at) as member_usernames
    from crew_members m
    join watchlist w on w.user_id = m.user_id
    join profiles p on p.id = m.user_id
    where m.crew_id = p_crew
      and public.is_crew_member(p_crew)
    group by w.movie_id
    having count(*) >= least(2, (select count(*) from crew_members
                                 where crew_id = p_crew))
    order by count(*) desc, max(w.created_at) desc
    limit 50;
$$;

revoke all on function public.crew_overlap(uuid) from public, anon;
grant execute on function public.crew_overlap(uuid) to authenticated;
