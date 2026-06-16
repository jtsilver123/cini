-- 0078_show_progress_notify_dedup.sql
-- Harden the friend_watching / caught_up notifications (0077): a user who
-- toggles state (e.g. "I'm caught up" → bump an episode → "I'm caught up"
-- again, or removes and re-adds a show) could otherwise re-notify the same
-- friends each cycle. Suppress a repeat of the same (recipient, actor, show,
-- kind) within 7 days.
create or replace function public.notify_show_progress()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if TG_OP = 'INSERT' and not new.caught_up then
        insert into notifications (recipient_id, actor_id, movie_id, kind)
        select sp.user_id, new.user_id, new.show_id, 'friend_watching'
        from show_progress sp
        join follows f on f.follower_id = sp.user_id and f.following_id = new.user_id
        where sp.show_id = new.show_id
          and sp.user_id <> new.user_id
          and not_blocked_pair(new.user_id, sp.user_id)
          and not exists (
            select 1 from notifications n
            where n.recipient_id = sp.user_id and n.actor_id = new.user_id
              and n.movie_id = new.show_id and n.kind = 'friend_watching'
              and n.created_at > now() - interval '7 days');
    end if;

    if new.caught_up and (TG_OP = 'INSERT' or not coalesce(old.caught_up, false)) then
        insert into notifications (recipient_id, actor_id, movie_id, kind)
        select sp.user_id, new.user_id, new.show_id, 'caught_up'
        from show_progress sp
        join follows f on f.follower_id = sp.user_id and f.following_id = new.user_id
        where sp.show_id = new.show_id
          and sp.user_id <> new.user_id
          and not_blocked_pair(new.user_id, sp.user_id)
          and not exists (
            select 1 from notifications n
            where n.recipient_id = sp.user_id and n.actor_id = new.user_id
              and n.movie_id = new.show_id and n.kind = 'caught_up'
              and n.created_at > now() - interval '7 days');
    end if;

    return new;
end $$;
