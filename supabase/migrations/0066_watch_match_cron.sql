-- 0066_watch_match_cron.sql
-- Nightly Watch Match detection: find new shared Want-to-Watch overlaps among
-- mutual-follow friends and notify both. Once per pair+title (unique row), so
-- it never re-nudges. Runs at 10:00 UTC, after the taste-match/predicted
-- refreshes.
select cron.schedule('watch-matches-nightly', '0 10 * * *',
                     'select public.detect_watch_matches()');
