-- Beli-style follow + approve.
--
-- Before this, follow() inserted a follows row instantly even for PRIVATE
-- accounts — which both skipped approval and immediately granted access to
-- their content (can_view() returns true once a follows row exists). Now:
--   • Public account  → follow is instant (a follows row, as before).
--   • Private account → a follow REQUEST the owner approves/denies. No follows
--     row exists until approval, so can_view() keeps requesters out.
-- Followers and following remain independent (the follows table is directional).

create table if not exists public.follow_requests (
    requester_id uuid not null references public.profiles(id) on delete cascade,
    target_id    uuid not null references public.profiles(id) on delete cascade,
    created_at   timestamptz not null default now(),
    primary key (requester_id, target_id),
    check (requester_id <> target_id)
);
alter table public.follow_requests enable row level security;

create policy "see own or incoming follow requests" on public.follow_requests
    for select using (requester_id = auth.uid() or target_id = auth.uid());
create policy "create own follow requests" on public.follow_requests
    for insert with check (requester_id = auth.uid());
create policy "cancel or respond to follow requests" on public.follow_requests
    for delete using (requester_id = auth.uid() or target_id = auth.uid());

-- New notification kinds.
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved']));

-- Follow a public account instantly, or request a private one. Returns
-- 'followed', 'requested', 'blocked', or 'self'.
create or replace function public.request_follow(p_target uuid)
returns text
language plpgsql security definer set search_path to 'public'
as $function$
declare v_me uuid := auth.uid(); v_private boolean;
begin
    if v_me is null or v_me = p_target then return 'self'; end if;
    if not not_blocked(p_target) then return 'blocked'; end if;
    if exists (select 1 from follows where follower_id = v_me and following_id = p_target) then
        return 'followed';
    end if;
    select is_private into v_private from profiles where id = p_target;
    if v_private is null then return 'self'; end if;
    if v_private then
        insert into follow_requests (requester_id, target_id) values (v_me, p_target)
            on conflict do nothing;
        if found then
            insert into notifications (recipient_id, actor_id, kind)
                values (p_target, v_me, 'follow_request');
        end if;
        return 'requested';
    else
        insert into follows (follower_id, following_id) values (v_me, p_target)
            on conflict do nothing;
        return 'followed';
    end if;
end $function$;

-- The target accepts or declines a pending request.
create or replace function public.respond_follow_request(p_requester uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path to 'public'
as $function$
declare v_me uuid := auth.uid();
begin
    delete from follow_requests where requester_id = p_requester and target_id = v_me;
    if not found then return; end if;
    if p_accept then
        insert into follows (follower_id, following_id) values (p_requester, v_me)
            on conflict do nothing;
        insert into notifications (recipient_id, actor_id, kind)
            values (p_requester, v_me, 'follow_request_approved');
    end if;
end $function$;

-- Pending requests addressed to me (for the approval list).
create or replace function public.incoming_follow_requests()
returns table(id uuid, username text, display_name text, avatar_url text, created_at timestamptz)
language sql stable security definer set search_path to 'public'
as $function$
    select p.id, p.username, p.display_name, p.avatar_url, fr.created_at
    from follow_requests fr
    join profiles p on p.id = fr.requester_id
    where fr.target_id = auth.uid()
    order by fr.created_at desc;
$function$;

revoke all on function public.request_follow(uuid) from public, anon;
revoke all on function public.respond_follow_request(uuid, boolean) from public, anon;
revoke all on function public.incoming_follow_requests() from public, anon;
grant execute on function public.request_follow(uuid) to authenticated;
grant execute on function public.respond_follow_request(uuid, boolean) to authenticated;
grant execute on function public.incoming_follow_requests() to authenticated;
