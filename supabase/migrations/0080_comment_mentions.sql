-- @-mentions in comments notify the tagged members (people you follow).
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved',
        'saved_your_rank','streak_reminder','tonight_pick','watch_match','watch_invite',
        'contact_joined','friend_watching','caught_up','mention']));

create or replace function public.notify_mention(p_event_id uuid, p_user_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_owner uuid;
    v_movie integer;
begin
    -- Only someone who can see the event (i.e. the commenter) may mention on it.
    select user_id, movie_id into v_owner, v_movie
    from feed_events where id = p_event_id and can_view(user_id);
    if v_owner is null then
        return;
    end if;
    -- Notify each tagged member you follow, except yourself and the event owner
    -- (who already gets a 'comment' notification).
    insert into notifications (recipient_id, actor_id, kind, event_id, movie_id)
    select distinct u, auth.uid(), 'mention', p_event_id, v_movie
    from unnest(p_user_ids) as u
    where u <> auth.uid() and u <> v_owner
      and exists (select 1 from follows f
                  where f.follower_id = auth.uid() and f.following_id = u);
end $$;

revoke execute on function public.notify_mention(uuid, uuid[]) from public, anon;
grant execute on function public.notify_mention(uuid, uuid[]) to authenticated;
