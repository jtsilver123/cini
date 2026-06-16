-- 0077_show_progress_notifications.sql
-- 1) Fix a regression: migrations 0063/0065 rebuilt notifications_kind_check
--    without 'contact_joined', so notify_contact_joined()'s insert (from 0059)
--    violated the constraint and failed. Restore it.
-- 2) Add two engagement notifications around Currently Watching:
--      friend_watching — a friend starts a show you're already watching
--      caught_up        — a friend gets caught up on a show you're watching
--    Both target only people who follow the actor AND are watching the same
--    show, so they're high-relevance, not spam.

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind = any (array[
    'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
    'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
    'rate_nudge','friend_loved','follow_request','follow_request_approved',
    'saved_your_rank','streak_reminder','tonight_pick','watch_match','watch_invite',
    'contact_joined','friend_watching','caught_up']));

create or replace function public.notify_show_progress()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    -- Started a show a follower is also watching (skip if it's an immediate
    -- "I'm caught up" start — that fires the caught_up note instead).
    if TG_OP = 'INSERT' and not new.caught_up then
        insert into notifications (recipient_id, actor_id, movie_id, kind)
        select sp.user_id, new.user_id, new.show_id, 'friend_watching'
        from show_progress sp
        join follows f on f.follower_id = sp.user_id and f.following_id = new.user_id
        where sp.show_id = new.show_id
          and sp.user_id <> new.user_id
          and not_blocked_pair(new.user_id, sp.user_id);
    end if;

    -- Just became caught up on a show a follower is also watching.
    if new.caught_up and (TG_OP = 'INSERT' or not coalesce(old.caught_up, false)) then
        insert into notifications (recipient_id, actor_id, movie_id, kind)
        select sp.user_id, new.user_id, new.show_id, 'caught_up'
        from show_progress sp
        join follows f on f.follower_id = sp.user_id and f.following_id = new.user_id
        where sp.show_id = new.show_id
          and sp.user_id <> new.user_id
          and not_blocked_pair(new.user_id, sp.user_id);
    end if;

    return new;
end $$;

drop trigger if exists trg_show_progress_notify on public.show_progress;
create trigger trg_show_progress_notify
    after insert or update on public.show_progress
    for each row execute function public.notify_show_progress();
