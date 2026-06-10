-- Remote push: device token registry + fan-out hook to the send-push
-- edge function whenever a notification row is created.
-- (Applied to production via MCP as `push_device_tokens`.)

create extension if not exists pg_net with schema extensions;

create table public.device_tokens (
  token text primary key,
  user_id uuid not null references auth.users(id) on delete cascade,
  platform text not null default 'ios',
  updated_at timestamptz not null default now()
);

alter table public.device_tokens enable row level security;

create policy "device_tokens_select_own" on public.device_tokens
  for select using (auth.uid() = user_id);
create policy "device_tokens_delete_own" on public.device_tokens
  for delete using (auth.uid() = user_id);

create or replace function public.register_device_token(p_token text, p_platform text default 'ios')
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  insert into device_tokens (token, user_id, platform)
  values (p_token, auth.uid(), p_platform)
  on conflict (token) do update
    set user_id = auth.uid(), platform = excluded.platform, updated_at = now();
end $$;

revoke all on function public.register_device_token(text, text) from anon;

create or replace function public.notify_push()
returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform net.http_post(
    url := 'https://npumchnkbcajyuhurgez.supabase.co/functions/v1/send-push',
    body := jsonb_build_object('notification_id', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json')
  );
  return new;
exception when others then
  return new;
end $$;

create trigger trg_notifications_push
  after insert on public.notifications
  for each row execute function public.notify_push();
