-- Avatar storage + in-app account deletion (mirrors prod migration
-- `avatars_and_account_deletion`). See 0007 for push.

insert into storage.buckets (id, name, public)
values ('avatars', 'avatars', true)
on conflict (id) do nothing;

create policy "avatar_read" on storage.objects
  for select using (bucket_id = 'avatars');
create policy "avatar_insert_own" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');
create policy "avatar_update_own" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');

create or replace function public.delete_account()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from auth.users where id = auth.uid();
end $$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
