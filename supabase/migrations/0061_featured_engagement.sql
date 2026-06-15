-- First-party engagement logging for the in-feed "Featured release" card.
-- This is OUR data only: impressions / opens / adds, never shared with any
-- third party, no IDFA, no cross-app linkage — so it is NOT Apple "tracking"
-- (no ATT prompt, no privacy-label tracking disclosure). Purpose: build real
-- performance numbers (CTR, add rate) to show distributors when we sell
-- promoted placements later.
create table if not exists public.featured_events (
  id bigint generated always as identity primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  movie_id integer not null,
  action text not null check (action in ('impression','open','add')),
  created_at timestamptz not null default now()
);
create index if not exists featured_events_movie_idx on public.featured_events (movie_id, action);
create index if not exists featured_events_created_idx on public.featured_events (created_at);

-- RLS on, no policies: the table is write-via-RPC and read-via-service-role
-- only. No client can read raw rows (analytics stays private).
alter table public.featured_events enable row level security;

-- Log one engagement event, attributed to the caller. Fire-and-forget from the
-- client; invalid actions are ignored so a bad call can never error the UI.
create or replace function public.log_featured_event(p_movie_id integer, p_action text)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  if p_action not in ('impression','open','add') then return; end if;
  insert into public.featured_events (user_id, movie_id, action)
    values (auth.uid(), p_movie_id, p_action);
end $$;
revoke all on function public.log_featured_event(integer, text) from public, anon;
grant execute on function public.log_featured_event(integer, text) to authenticated;

-- Aggregate read for the founder's sales numbers. Service-role only (run from
-- the Supabase SQL editor / dashboard) — never exposed to app clients.
create or replace function public.featured_engagement_stats()
returns table(movie_id integer, impressions bigint, opens bigint, adds bigint,
              open_rate numeric, add_rate numeric)
language sql security definer set search_path = public stable as $$
  select movie_id,
         count(*) filter (where action='impression') as impressions,
         count(*) filter (where action='open') as opens,
         count(*) filter (where action='add') as adds,
         round(100.0 * count(*) filter (where action='open')
               / nullif(count(*) filter (where action='impression'), 0), 1) as open_rate,
         round(100.0 * count(*) filter (where action='add')
               / nullif(count(*) filter (where action='impression'), 0), 1) as add_rate
  from public.featured_events
  group by movie_id
  order by impressions desc
$$;
revoke all on function public.featured_engagement_stats() from public, anon, authenticated;
