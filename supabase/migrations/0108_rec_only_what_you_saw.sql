-- 0108_rec_only_what_you_saw.sql
-- You can only recommend a title you've actually seen (ranked). The movie page
-- now hides the Recommend button until you've ranked it; this is the server-side
-- backstop that also covers Ask Cini and any future surface. Otherwise identical
-- to 0081.
create or replace function public.send_direct_rec(p_recipient uuid, p_movie_id integer, p_note text default null::text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_inserted boolean;
begin
  if auth.uid() is null or p_recipient = auth.uid() then
    return false;
  end if;
  if not exists (
    select 1 from follows
    where follower_id = auth.uid() and following_id = p_recipient
  ) then
    return false;
  end if;
  -- You haven't seen it (no ranking of your own)? Nothing to vouch for.
  if not exists (
    select 1 from rankings
    where user_id = auth.uid() and movie_id = p_movie_id
  ) then
    return false;
  end if;
  -- Recipient already ranked (seen) it? There's nothing to recommend.
  if exists (
    select 1 from rankings
    where user_id = p_recipient and movie_id = p_movie_id
  ) then
    return false;
  end if;

  insert into direct_recs (sender_id, recipient_id, movie_id, note)
  values (auth.uid(), p_recipient, p_movie_id, nullif(trim(p_note), ''))
  on conflict (sender_id, recipient_id, movie_id)
    do update set note = excluded.note, created_at = now()
  returning (xmax = 0) into v_inserted;

  -- Only a brand-new rec notifies; note edits stay quiet.
  if v_inserted then
    insert into notifications (recipient_id, actor_id, kind, movie_id)
    values (p_recipient, auth.uid(), 'direct_rec', p_movie_id);
  end if;
  return true;
end $function$;
