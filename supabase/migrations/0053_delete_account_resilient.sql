-- Make account deletion resilient. Migration 0047 added an avatar
-- Storage cleanup to delete_account; if that delete hits a permissions
-- issue it aborted the WHOLE function, so "Delete my account" failed with
-- "Couldn't delete the account." App Store requires deletion to work, so
-- the avatar cleanup is now best-effort and can never block the auth.users
-- delete (which is the part that actually removes the account + cascades).

create or replace function public.delete_account()
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  begin
    delete from storage.objects
     where bucket_id = 'avatars' and name = auth.uid()::text || '.jpg';
  exception when others then
    null;  -- never block deletion on avatar cleanup
  end;
  delete from auth.users where id = auth.uid();
end $$;
