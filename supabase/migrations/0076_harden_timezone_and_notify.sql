-- 0076_harden_timezone_and_notify.sql
-- Audit hardening:
-- 1) A single malformed profiles.timezone string makes `now() at time zone tz`
--    raise inside tonight_pick_candidates(), which is evaluated set-wide — so one
--    bad row aborted the WHOLE Tonight's Pick push (the edge function caught the
--    error and returned 200, so it failed silently for everyone). Validate the
--    timezone on write, and defensively skip invalid rows in the candidate query.
-- 2) notify_saved_your_rank ignored blocks — a blocked user could still be
--    notified. Gate it with not_blocked_pair like the other notification paths.

-- Reject an unrecognized IANA timezone instead of storing it.
create or replace function public.set_timezone(p_tz text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not authenticated'; end if;
  if p_tz is null or not exists (select 1 from pg_timezone_names where name = p_tz) then
    raise exception 'invalid timezone: %', p_tz;
  end if;
  update public.profiles set timezone = p_tz, updated_at = now() where id = auth.uid();
end $$;
revoke all on function public.set_timezone(text) from public, anon;
grant execute on function public.set_timezone(text) to authenticated;

-- Defensively ignore any timezone that isn't a known IANA name so a legacy bad
-- row can never abort the whole candidate query again.
create or replace function public.tonight_pick_candidates()
returns table(user_id uuid, local_date date)
language sql stable security definer set search_path = public as $$
  select p.id, (now() at time zone p.timezone)::date as local_date
  from profiles p
  where p.timezone is not null
    and p.timezone in (select name from pg_timezone_names)
    and extract(hour from (now() at time zone p.timezone)) = 19
    and not ('tonight_pick' = any(p.muted_notification_kinds))
    and exists (select 1 from device_tokens d where d.user_id = p.id)
    and not exists (
      select 1 from tonight_pick_sends t
      where t.user_id = p.id and t.sent_on = (now() at time zone p.timezone)::date
    );
$$;
revoke all on function public.tonight_pick_candidates() from public, anon, authenticated;

-- Don't notify someone who's in a block relationship with the saver.
create or replace function public.notify_saved_your_rank()
returns trigger
language plpgsql security definer set search_path to 'public'
as $function$
begin
    insert into notifications (recipient_id, actor_id, movie_id, kind)
    select r.user_id, new.user_id, new.movie_id, 'saved_your_rank'
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = new.user_id
    where r.movie_id = new.movie_id and r.user_id <> new.user_id
      and not_blocked_pair(new.user_id, r.user_id);
    return new;
end $function$;
