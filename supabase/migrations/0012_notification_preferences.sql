-- Per-kind notification preferences (mirrors prod migration
-- `notification_preferences`). Muting is enforced at creation: a BEFORE
-- INSERT trigger drops rows for muted kinds, silencing bell + push.

alter table public.profiles
  add column if not exists muted_notification_kinds text[] not null default '{}';

create or replace function public.filter_muted_notifications()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if exists (
    select 1 from profiles
    where id = new.recipient_id
      and new.kind = any(muted_notification_kinds)
  ) then
    return null;
  end if;
  return new;
end $$;

create trigger trg_notifications_mute
  before insert on public.notifications
  for each row execute function public.filter_muted_notifications();
