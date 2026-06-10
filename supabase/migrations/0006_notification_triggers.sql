-- Notifications for the social loop: follows, likes, and comments now
-- notify the affected user (rank_insert already notifies watchlist holders).

create or replace function public.notify_on_follow() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into notifications (recipient_id, actor_id, kind)
    values (new.following_id, new.follower_id, 'new_follower');
    return new;
end $$;
revoke execute on function public.notify_on_follow() from public, anon, authenticated;

create trigger on_follow_created
    after insert on public.follows
    for each row execute function public.notify_on_follow();

create or replace function public.notify_on_like() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    v_owner uuid;
    v_movie integer;
begin
    select user_id, movie_id into v_owner, v_movie from feed_events where id = new.event_id;
    if v_owner is not null and v_owner <> new.user_id then
        insert into notifications (recipient_id, actor_id, kind, event_id, movie_id)
        values (v_owner, new.user_id, 'like', new.event_id, v_movie);
    end if;
    return new;
end $$;
revoke execute on function public.notify_on_like() from public, anon, authenticated;

create trigger on_like_created
    after insert on public.likes
    for each row execute function public.notify_on_like();

create or replace function public.notify_on_comment() returns trigger
language plpgsql security definer set search_path = public as $$
declare
    v_owner uuid;
    v_movie integer;
begin
    select user_id, movie_id into v_owner, v_movie from feed_events where id = new.event_id;
    if v_owner is not null and v_owner <> new.user_id then
        insert into notifications (recipient_id, actor_id, kind, event_id, movie_id)
        values (v_owner, new.user_id, 'comment', new.event_id, v_movie);
    end if;
    return new;
end $$;
revoke execute on function public.notify_on_comment() from public, anon, authenticated;

create trigger on_comment_created
    after insert on public.comments
    for each row execute function public.notify_on_comment();
