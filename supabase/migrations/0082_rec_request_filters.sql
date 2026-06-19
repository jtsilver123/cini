-- CIN-22: rec requests can carry the full filter set (decade, max runtime,
-- streaming provider) in addition to media kind + genre. Drop/recreate
-- request_recs with the new params (adding args changes its signature, so a
-- plain CREATE OR REPLACE would leave a stale overload).
alter table rec_requests
    add column if not exists decade int,
    add column if not exists max_runtime int,
    add column if not exists streaming_provider text;

drop function if exists public.request_recs(uuid[], text, text, text);

create or replace function public.request_recs(
    p_recipients uuid[],
    p_media_kind text default null,
    p_genre text default null,
    p_note text default null,
    p_decade int default null,
    p_max_runtime int default null,
    p_streaming_provider text default null)
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

        insert into rec_requests (requester_id, recipient_id, media_kind, genre, note,
                                  decade, max_runtime, streaming_provider)
        values (auth.uid(), v_recipient, p_media_kind,
                nullif(trim(p_genre), ''), nullif(trim(p_note), ''),
                p_decade, p_max_runtime, nullif(trim(p_streaming_provider), ''))
        on conflict (requester_id, recipient_id) where fulfilled_at is null
            do update set media_kind = excluded.media_kind,
                          genre = excluded.genre,
                          note = excluded.note,
                          decade = excluded.decade,
                          max_runtime = excluded.max_runtime,
                          streaming_provider = excluded.streaming_provider,
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

grant execute on function public.request_recs(uuid[], text, text, text, int, int, text) to authenticated;
