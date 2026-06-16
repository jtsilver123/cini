-- 0064_tonight_pick_cron.sql
-- Hourly trigger for the evening Tonight's Pick push. Each run hits the
-- tonight-pick edge function, which sends to whoever is currently in their
-- local 7pm hour (tonight_pick_candidates does the timezone math). Runs at :05
-- past every hour so each timezone's 7pm window is covered exactly once a day;
-- the per-user once-a-day dedup row guarantees no double-sends.

select cron.schedule(
  'tonight-pick-hourly',
  '5 * * * *',
  $$
  select net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/tonight-pick',
    body := '{}'::jsonb,
    headers := '{"Content-Type": "application/json"}'::jsonb
  );
  $$
);
