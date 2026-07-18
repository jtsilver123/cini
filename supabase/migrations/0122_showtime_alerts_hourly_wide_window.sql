-- Ticket on-sale alerts must beat sellouts: the nightly, today-only scan
-- becomes HOURLY, and the function now sweeps ~70 days ahead (advance
-- sales fire the moment they're listed). Cadence lives here; the window
-- logic lives in the showtime-alerts edge function.
select cron.unschedule('showtime-alerts-daily');
select cron.schedule(
  'showtime-alerts-hourly',
  '20 * * * *',
  $$
  select net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/showtime-alerts',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  $$
);
