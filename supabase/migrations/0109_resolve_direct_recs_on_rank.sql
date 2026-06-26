-- When you rank a title a friend directly recommended to you, clear it from your
-- Friend Recs and tell the friend you watched it. Done in the DB so it fires for
-- every rank path (app, import, Ask Cini) atomically with the ranking.

-- Allow the new notification kind.
alter table notifications drop constraint if exists notifications_kind_check;
alter table notifications add constraint notifications_kind_check check (
    kind = any (array[
        'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
        'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
        'rate_nudge','friend_loved','follow_request','follow_request_approved','saved_your_rank',
        'streak_reminder','tonight_pick','watch_match','watch_invite','contact_joined',
        'friend_watching','caught_up','mention','rec_passed','rec_watched'
    ])
);

-- On a new ranking, resolve any direct recs of that title sent TO the ranker:
-- notify each sender they watched it, then clear the rec from the recipient's
-- Friend Recs. SECURITY DEFINER so it can notify the sender (a different user).
create or replace function public.resolve_direct_recs_on_rank()
returns trigger language plpgsql security definer set search_path = public as $$
declare r record;
begin
    for r in
        select id, sender_id from direct_recs
        where recipient_id = NEW.user_id
          and movie_id = NEW.movie_id
          and sender_id <> NEW.user_id
    loop
        insert into notifications (recipient_id, actor_id, kind, movie_id)
        values (r.sender_id, NEW.user_id, 'rec_watched', NEW.movie_id);
        delete from direct_recs where id = r.id;
    end loop;
    return NEW;
end $$;

drop trigger if exists rankings_resolve_direct_recs on rankings;
create trigger rankings_resolve_direct_recs
    after insert on rankings
    for each row execute function public.resolve_direct_recs_on_rank();
