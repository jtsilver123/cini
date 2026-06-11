-- The kind check was never updated for the three newer notification
-- kinds, so the inserts violated it and rolled back their WHOLE
-- transactions: send_direct_rec never created the rec, redeem_invite_from
-- never created the mutual follow, and showtime alerts never delivered.
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('like', 'comment', 'new_follower',
                  'friend_ranked_watchlist_movie',
                  'direct_rec', 'invite_joined', 'watchlist_showing'));

-- showtime_notices rows were written BEFORE the failed notification
-- insert, permanently marking users as already-alerted for showings they
-- never heard about. Clear them so the nightly job can re-alert.
delete from public.showtime_notices;
