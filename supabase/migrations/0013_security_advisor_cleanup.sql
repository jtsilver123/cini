-- Advisor cleanup (mirrors prod migration `security_advisor_cleanup`):
-- trigger functions out of the REST API, register_device_token PUBLIC
-- grant fixed, avatars bucket listing policy dropped (URLs stay public).
revoke all on function public.filter_muted_notifications() from public, anon, authenticated;
revoke all on function public.notify_push() from public, anon, authenticated;
revoke all on function public.register_device_token(text, text) from public, anon;
grant execute on function public.register_device_token(text, text) to authenticated;
drop policy if exists "avatar_read" on storage.objects;
