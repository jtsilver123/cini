-- Account deletion must also remove the user's avatar from Storage.
-- storage.objects has no FK to auth.users, so the on-delete cascade that
-- wipes a user's Postgres rows leaves their avatar (`<uid>.jpg` in the
-- public `avatars` bucket) publicly fetchable after they delete their
-- account. Delete it inside the RPC so "delete my account" truly removes
-- all of the user's data. SECURITY DEFINER runs as the owner and bypasses
-- RLS, so no extra storage policy is needed.

create or replace function public.delete_account()
returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  delete from storage.objects
   where bucket_id = 'avatars'
     and name = auth.uid()::text || '.jpg';
  delete from auth.users where id = auth.uid();
end $$;

revoke all on function public.delete_account() from public, anon;
grant execute on function public.delete_account() to authenticated;
