-- Avatar uploads returned 400 because the bucket had INSERT/UPDATE
-- policies but NO SELECT policy — Storage's upload does INSERT ...
-- RETURNING, which needs SELECT, so RLS denied the whole write (no
-- avatar had ever uploaded). Rebuild a complete, standard set: anyone
-- can read (the bucket is public), authenticated users manage only
-- their own "{uid}.jpg". Applied to prod as `avatar_storage_policies`.
drop policy if exists avatar_insert_own on storage.objects;
drop policy if exists avatar_update_own on storage.objects;
drop policy if exists avatar_select_public on storage.objects;
drop policy if exists avatar_delete_own on storage.objects;

create policy avatar_select_public on storage.objects
    for select using (bucket_id = 'avatars');

create policy avatar_insert_own on storage.objects
    for insert to authenticated
    with check (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');

create policy avatar_update_own on storage.objects
    for update to authenticated
    using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg')
    with check (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');

create policy avatar_delete_own on storage.objects
    for delete to authenticated
    using (bucket_id = 'avatars' and name = auth.uid()::text || '.jpg');
