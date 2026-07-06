-- 0115_notification_burst_cap.sql
-- Never bombard a user (audit follow-up). The existing dedupes are all
-- per-movie: when one user saves TWENTY DIFFERENT titles another user has
-- ranked (a browsing spree, or an import seeding a big watchlist), the
-- ranker still got twenty separate "saved your rank" bell rows + pushes.
-- Same shape for a friend bulk-ranking titles on your watchlist
-- (friend_ranked_watchlist_movie), bulk-ranking your favorites
-- (friend_loved / rec_watched), or binge progress (friend_watching /
-- caught_up).
--
-- Fix: a rate cap at the notifications choke point (BEFORE INSERT, like the
-- mute and block filters), applied to the passive-activity kinds only. Per
-- (recipient, actor, kind): at most 3 per hour and 5 per day — the first few
-- land (they're delightful), the rest of the burst is silently dropped, which
-- silences both the bell row and the push (pushes fan out from the inserted
-- row). Deliberate person-to-person acts (recs, mentions, comments, likes,
-- follows, watch invites) are NOT capped — each one is individually meant.

create index if not exists notifications_burst_idx
    on public.notifications (recipient_id, actor_id, kind, created_at);

create or replace function public.filter_notification_bursts()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
    if new.actor_id is null then
        return new;
    end if;
    if new.kind not in ('saved_your_rank', 'friend_ranked_watchlist_movie',
                        'friend_loved', 'rec_watched',
                        'friend_watching', 'caught_up') then
        return new;
    end if;
    if (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.actor_id = new.actor_id
          and n.kind = new.kind
          and n.created_at > now() - interval '1 hour') >= 3
    or (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.actor_id = new.actor_id
          and n.kind = new.kind
          and n.created_at > now() - interval '24 hours') >= 5
    then
        return null;
    end if;
    return new;
end $$;

drop trigger if exists trg_notifications_burst on public.notifications;
create trigger trg_notifications_burst
    before insert on public.notifications
    for each row execute function public.filter_notification_bursts();
