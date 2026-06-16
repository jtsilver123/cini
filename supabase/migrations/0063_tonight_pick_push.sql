-- 0063_tonight_pick_push.sql
-- Evening push for Tonight's Pick: notify each user their daily pick at ~7pm in
-- THEIR local time. Needs a per-user timezone, a once-a-day dedup, a candidate
-- query the hourly cron/edge-function uses, and the new notification kind.

-- Per-user timezone (IANA id, e.g. America/New_York), set by the app on launch.
alter table public.profiles add column if not exists timezone text;

create or replace function public.set_timezone(p_tz text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  update public.profiles set timezone = p_tz, updated_at = now() where id = auth.uid();
end $$;
revoke all on function public.set_timezone(text) from public, anon;
grant execute on function public.set_timezone(text) to authenticated;

-- One tonight push per user per local day.
create table if not exists public.tonight_pick_sends (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  sent_on  date not null,
  movie_id integer,
  primary key (user_id, sent_on)
);
alter table public.tonight_pick_sends enable row level security;
-- Service-role only — no client policies (deny-all to authenticated/anon).

-- Add 'tonight_pick' to the allowed notification kinds.
alter table public.notifications drop constraint if exists notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind = any (array[
    'like','comment','new_follower','friend_ranked_watchlist_movie','direct_rec',
    'invite_joined','watchlist_showing','rec_request','streaming_now','season_premiere',
    'rate_nudge','friend_loved','follow_request','follow_request_approved',
    'saved_your_rank','streak_reminder','tonight_pick']));

-- Who should get a tonight push right now: local time is the 7pm hour, they
-- haven't muted it, they have at least one device, and they haven't been sent
-- today. The hourly cron/edge-function reads this and sends to each.
create or replace function public.tonight_pick_candidates()
returns table(user_id uuid, local_date date)
language sql stable security definer set search_path = public as $$
  select p.id, (now() at time zone p.timezone)::date as local_date
  from profiles p
  where p.timezone is not null
    and extract(hour from (now() at time zone p.timezone)) = 19
    and not ('tonight_pick' = any(p.muted_notification_kinds))
    and exists (select 1 from device_tokens d where d.user_id = p.id)
    and not exists (
      select 1 from tonight_pick_sends t
      where t.user_id = p.id and t.sent_on = (now() at time zone p.timezone)::date
    );
$$;
revoke all on function public.tonight_pick_candidates() from public, anon, authenticated;
