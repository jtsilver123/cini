-- Blocking must actually sever the relationship (audit finding).
--
-- Before this: blocking only hid content behind can_view(). The follow
-- edges survived, every follow-driven notification writer (rank_insert's
-- friend_ranked / rec_watched, saved_your_rank, friend_loved, likes,
-- comments, mentions, follows) kept notifying across the block in both
-- directions, and pushes delivered. The app's toast says "their content
-- is hidden everywhere" -- make that true.
--
-- 1) One choke point: a BEFORE INSERT trigger on notifications drops any
--    row between a blocked pair, whichever direction. Covers every writer,
--    present and future, without touching each function.
-- 2) Blocking severs follow edges + pending requests both ways (trigger),
--    and the follows INSERT policy refuses new edges across a block (the
--    plain-insert path skipped request_follow's check).
-- 3) notify_saved_your_rank gets a 30-day dedupe per (recipient, actor,
--    movie) -- rapid bookmark toggling on a popular title spammed every
--    followed ranker with identical pushes.
-- 4) hide_watchlist_save(p_movie_id): one RPC that hides a save -- deletes
--    the caller's 'watchlisted' feed event AND recalls the saved_your_rank
--    bell rows it created (already-delivered pushes can't be unsent, but
--    the in-app trail disappears).

-- (1) Drop notifications between blocked pairs, either direction.
create or replace function public.filter_blocked_notifications()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if new.actor_id is not null and exists (
        select 1 from blocks b
        where (b.blocker_id = new.recipient_id and b.blocked_id = new.actor_id)
           or (b.blocker_id = new.actor_id and b.blocked_id = new.recipient_id)
    ) then
        return null;
    end if;
    return new;
end $$;

drop trigger if exists trg_notifications_block on public.notifications;
create trigger trg_notifications_block
    before insert on public.notifications
    for each row execute function public.filter_blocked_notifications();

-- (2) Blocking severs the social graph both ways.
create or replace function public.sever_on_block()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    delete from follows
    where (follower_id = new.blocker_id and following_id = new.blocked_id)
       or (follower_id = new.blocked_id and following_id = new.blocker_id);
    delete from follow_requests
    where (requester_id = new.blocker_id and target_id = new.blocked_id)
       or (requester_id = new.blocked_id and target_id = new.blocker_id);
    return new;
end $$;

drop trigger if exists trg_block_severs on public.blocks;
create trigger trg_block_severs
    after insert on public.blocks
    for each row execute function public.sever_on_block();

-- Backfill: sever edges for blocks that already exist.
delete from public.follows f
using public.blocks b
where (f.follower_id = b.blocker_id and f.following_id = b.blocked_id)
   or (f.follower_id = b.blocked_id and f.following_id = b.blocker_id);
delete from public.follow_requests r
using public.blocks b
where (r.requester_id = b.blocker_id and r.target_id = b.blocked_id)
   or (r.requester_id = b.blocked_id and r.target_id = b.blocker_id);

-- The plain INSERT path must refuse edges across a block, like request_follow.
drop policy if exists follows_insert on public.follows;
create policy follows_insert on public.follows
    for insert to authenticated
    with check (follower_id = auth.uid() and public.not_blocked(following_id));

-- (3) saved_your_rank: don't re-notify the same person about the same
-- actor/movie within 30 days (bookmark toggling re-fires the trigger).
create or replace function public.notify_saved_your_rank()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    insert into notifications (recipient_id, actor_id, movie_id, kind)
    select r.user_id, new.user_id, new.movie_id, 'saved_your_rank'
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = new.user_id
    where r.movie_id = new.movie_id and r.user_id != new.user_id
      and not exists (
        select 1 from notifications n
        where n.recipient_id = r.user_id and n.actor_id = new.user_id
          and n.movie_id = new.movie_id and n.kind = 'saved_your_rank'
          and n.created_at > now() - interval '30 days'
      );
    return new;
end $function$;

-- (4) Hide a save: feed event AND its bell rows, in one call.
create or replace function public.hide_watchlist_save(p_movie_id integer)
returns void
language sql security definer set search_path = public as $$
    delete from feed_events
    where user_id = auth.uid() and movie_id = p_movie_id
      and event_type = 'watchlisted';
    delete from notifications
    where actor_id = auth.uid() and movie_id = p_movie_id
      and kind = 'saved_your_rank';
$$;

revoke all on function public.hide_watchlist_save(integer) from public, anon;
grant execute on function public.hide_watchlist_save(integer) to authenticated;
