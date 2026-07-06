-- 0116_global_notification_caps.sql
-- "Never bombard me" — the remaining two layers on top of 0115's per-friend
-- cap (which stops ONE friend's bulk session, but not twenty friends acting
-- in the same hour, and caps rows per friend, not the phone itself).
--
-- Layer 2 — cross-friend cap on passive-activity rows (bell + push):
--   the passive kinds are FYI-grade; regardless of HOW MANY friends are
--   saving/ranking your titles, at most 6 such rows land per hour and 15 per
--   day. Deliberate one-to-one acts stay uncapped here — each is meant.
--
-- Layer 3 — a hard push throttle for EVERYTHING (the buzz guarantee):
--   the phone buzzes at most 5 times per hour and 15 times per day, total,
--   across all kinds. Past the cap, notifications still land in the bell
--   (nothing is lost) — the lock screen just goes quiet. Counting rows
--   received approximates pushes sent, and it errs quiet during a flood,
--   which is exactly when quiet is right.

-- Layer 2: extend the burst filter with a global passive-kind cap.
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
    -- Per-friend cap (0115): one friend's bulk session.
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
    -- Cross-friend cap: many friends acting in the same window.
    if (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.kind in ('saved_your_rank', 'friend_ranked_watchlist_movie',
                         'friend_loved', 'rec_watched',
                         'friend_watching', 'caught_up')
          and n.created_at > now() - interval '1 hour') >= 6
    or (select count(*) from notifications n
        where n.recipient_id = new.recipient_id
          and n.kind in ('saved_your_rank', 'friend_ranked_watchlist_movie',
                         'friend_loved', 'rec_watched',
                         'friend_watching', 'caught_up')
          and n.created_at > now() - interval '24 hours') >= 15
    then
        return null;
    end if;
    return new;
end $$;

-- Layer 3: the push fan-out goes quiet past 5 buzzes/hour or 15/day —
-- the bell row above still landed, so nothing is lost.
create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from notifications n
      where n.recipient_id = new.recipient_id
        and n.id != new.id
        and n.created_at > now() - interval '1 hour') >= 5
  or (select count(*) from notifications n
      where n.recipient_id = new.recipient_id
        and n.id != new.id
        and n.created_at > now() - interval '24 hours') >= 15
  then
    return new;
  end if;
  perform net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/send-push',
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
exception when others then
  return new;
end $$;
