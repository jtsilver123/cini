-- Ask friends for a rec (Beli-style): requester multi-selects friends +
-- optional type/genre/note; each friend gets a 'rec_request' notification
-- (push rides the existing notify_push trigger; send-push v7 adds the
-- headline) and answers with normal direct recs, which fulfill the
-- request via complete_rec_request. Applied to prod as `rec_requests`.

create table public.rec_requests (
    id uuid primary key default gen_random_uuid(),
    requester_id uuid not null references public.profiles(id) on delete cascade,
    recipient_id uuid not null references public.profiles(id) on delete cascade,
    media_kind text check (media_kind in ('movie', 'tv')),  -- null = any
    genre text,                                             -- null = any
    note text,
    created_at timestamptz not null default now(),
    fulfilled_at timestamptz
);

-- One pending ask per (requester, recipient); re-asking updates it
-- quietly (same anti-spam shape as direct_recs_dedupe).
create unique index rec_requests_pending_unique
    on public.rec_requests (requester_id, recipient_id)
    where fulfilled_at is null;
create index rec_requests_recipient_idx
    on public.rec_requests (recipient_id) where fulfilled_at is null;

alter table public.rec_requests enable row level security;
create policy rec_requests_select on public.rec_requests for select
    using (auth.uid() = requester_id or auth.uid() = recipient_id);
-- All writes go through the security-definer RPCs below.

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array['like', 'comment', 'new_follower',
                             'friend_ranked_watchlist_movie', 'direct_rec',
                             'invite_joined', 'watchlist_showing',
                             'rec_request']));

create or replace function public.request_recs(
    p_recipients uuid[],
    p_media_kind text default null,
    p_genre text default null,
    p_note text default null)
returns integer
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_recipient uuid;
    v_sent integer := 0;
    v_inserted boolean;
begin
    if auth.uid() is null then return 0; end if;
    if p_media_kind is not null and p_media_kind not in ('movie', 'tv') then
        return 0;
    end if;
    foreach v_recipient in array p_recipients loop
        if v_recipient = auth.uid() then continue; end if;
        if not exists (
            select 1 from follows
            where follower_id = auth.uid() and following_id = v_recipient
        ) then continue; end if;
        if exists (
            select 1 from blocks
            where (blocker_id = v_recipient and blocked_id = auth.uid())
               or (blocker_id = auth.uid() and blocked_id = v_recipient)
        ) then continue; end if;

        insert into rec_requests (requester_id, recipient_id, media_kind, genre, note)
        values (auth.uid(), v_recipient, p_media_kind,
                nullif(trim(p_genre), ''), nullif(trim(p_note), ''))
        on conflict (requester_id, recipient_id) where fulfilled_at is null
            do update set media_kind = excluded.media_kind,
                          genre = excluded.genre,
                          note = excluded.note,
                          created_at = now()
        returning (xmax = 0) into v_inserted;

        -- Only a brand-new ask notifies; criteria edits stay quiet.
        if v_inserted then
            insert into notifications (recipient_id, actor_id, kind)
            values (v_recipient, auth.uid(), 'rec_request');
        end if;
        v_sent := v_sent + 1;
    end loop;
    return v_sent;
end $function$;

create or replace function public.complete_rec_request(p_request_id uuid)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_count integer;
begin
    update rec_requests set fulfilled_at = now()
    where id = p_request_id and recipient_id = auth.uid()
      and fulfilled_at is null;
    get diagnostics v_count = row_count;
    return v_count > 0;
end $function$;

-- create or replace resets grants to PUBLIC — pin them (0025 lesson).
revoke all on function public.request_recs(uuid[], text, text, text) from public, anon;
grant execute on function public.request_recs(uuid[], text, text, text) to authenticated;
revoke all on function public.complete_rec_request(uuid) from public, anon;
grant execute on function public.complete_rec_request(uuid) to authenticated;
