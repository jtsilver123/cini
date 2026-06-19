-- CIN-36: passing on a friend's rec can carry an optional message back to the
-- friend ("not my thing because…"). Notifications gain a free-text `message`,
-- a new `rec_passed` kind, and an RPC that dismisses the rec + notifies the
-- sender when a message is given.
alter table notifications add column if not exists message text;

alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (
    kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved','saved_your_rank',
        'streak_reminder','tonight_pick','watch_match','watch_invite','contact_joined',
        'friend_watching','caught_up','mention','rec_passed'
    ])
);

create or replace function public.pass_direct_rec(p_rec_id uuid, p_message text default null)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_sender uuid;
    v_movie int;
    v_msg text := nullif(trim(p_message), '');
begin
    if auth.uid() is null then return false; end if;
    select sender_id, movie_id into v_sender, v_movie
    from direct_recs where id = p_rec_id and recipient_id = auth.uid();
    if v_sender is null then return false; end if;

    delete from direct_recs where id = p_rec_id and recipient_id = auth.uid();

    -- Only notify when there's actually something to say.
    if v_msg is not null then
        insert into notifications (recipient_id, actor_id, kind, movie_id, message)
        values (v_sender, auth.uid(), 'rec_passed', v_movie, v_msg);
    end if;
    return true;
end $function$;

grant execute on function public.pass_direct_rec(uuid, text) to authenticated;
