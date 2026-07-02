-- Audit hardening + one behavior fix.
--
-- 1) Pin search_path on the two remaining functions the security advisor
--    flags as role-mutable (phone_key, slugify). Both are pure regexp
--    helpers, but they're called from SECURITY DEFINER functions, so a
--    pinned path removes the (theoretical) hijack surface and the WARN.
--
-- 2) notify_mention: allow tagging someone who COMMENTED on the same
--    event, not only people you follow. Replying to a stranger's comment
--    on your post prefills their @handle -- the app promises that tags
--    them, but the follows-only filter silently dropped the notification.
--    Commenting on a thread is engagement enough to be taggable there.

alter function public.phone_key(text) set search_path = '';
alter function public.slugify(text, int) set search_path = '';

create or replace function public.notify_mention(p_event_id uuid, p_user_ids uuid[])
returns void
language plpgsql security definer set search_path = public as $$
declare
    v_owner uuid;
    v_movie integer;
begin
    -- Only someone who can see the event (i.e. the commenter) may mention on it.
    select user_id, movie_id into v_owner, v_movie
    from feed_events where id = p_event_id and can_view(user_id);
    if v_owner is null then
        return;
    end if;
    -- Notify each tagged member, except yourself and the event owner (who
    -- already gets a 'comment' notification). Taggable = someone you follow,
    -- OR someone who commented on this same event (so replies to strangers
    -- in your thread actually tag them).
    insert into notifications (recipient_id, actor_id, kind, event_id, movie_id)
    select distinct u, auth.uid(), 'mention', p_event_id, v_movie
    from unnest(p_user_ids) as u
    where u != auth.uid() and u != v_owner
      and (
        exists (select 1 from follows f
                where f.follower_id = auth.uid() and f.following_id = u)
        or exists (select 1 from comments c
                   where c.event_id = p_event_id and c.user_id = u)
      );
end $$;
