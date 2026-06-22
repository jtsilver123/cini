-- The weekly streak-reminder push still decided "hasn't ranked this week" in
-- UTC, while rank_insert (0094) now stamps last_logged_week in the user's local
-- week. That mismatch could nudge a behind-UTC user who actually ranked in
-- their local week. Use the stored per-user timezone (set on launch via
-- set_timezone), defensively falling back to UTC for a missing/invalid value —
-- the same hardening pattern as 0076.
do $$ begin perform cron.unschedule('streak-reminders'); exception when others then null; end $$;
select cron.schedule('streak-reminders', '0 17 * * 6',
$job$
    insert into notifications (recipient_id, kind)
    select p.id, 'streak_reminder'
    from profiles p
    where p.streak_weeks > 0
      and (p.last_logged_week is null
           or p.last_logged_week < date_trunc('week',
                now() at time zone coalesce(
                    (select name from pg_timezone_names where name = p.timezone), 'UTC'))::date)
$job$);
