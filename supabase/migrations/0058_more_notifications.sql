-- Two new notification types (the mute filter + push fire automatically on
-- any insert into notifications, so these triggers just insert).

alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
    check (kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved',
        'saved_your_rank','streak_reminder']));

-- #1 "Your taste influenced a friend": when someone adds a title to Want to
-- Watch, tell the people THEY follow who have already ranked it.
create or replace function public.notify_saved_your_rank()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    insert into notifications (recipient_id, actor_id, movie_id, kind)
    select r.user_id, new.user_id, new.movie_id, 'saved_your_rank'
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = new.user_id
    where r.movie_id = new.movie_id and r.user_id <> new.user_id;
    return new;
end $function$;

drop trigger if exists trg_saved_your_rank on public.watchlist;
create trigger trg_saved_your_rank
    after insert on public.watchlist
    for each row execute function public.notify_saved_your_rank();

-- #3 Streak reminder: a weekly nudge (Saturday) for anyone with a live streak
-- they haven't fed this week. Inserting the notification sends the push.
do $$ begin perform cron.unschedule('streak-reminders'); exception when others then null; end $$;
select cron.schedule('streak-reminders', '0 17 * * 6',
$job$
    insert into notifications (recipient_id, kind)
    select p.id, 'streak_reminder'
    from profiles p
    where p.streak_weeks > 0
      and (p.last_logged_week is null
           or p.last_logged_week < date_trunc('week', now())::date)
$job$);
