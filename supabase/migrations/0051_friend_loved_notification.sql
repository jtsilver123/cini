-- "A friend rated one of your favorites" notification: after you rank a title,
-- the people who follow you AND already rate that title highly get notified.

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('like','comment','new_follower','friend_ranked_watchlist_movie',
                  'direct_rec','invite_joined','watchlist_showing','rec_request',
                  'streaming_now','season_premiere','rate_nudge','friend_loved'));

create or replace function public.notify_friends_of_rating(p_movie_id integer)
returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return; end if;
  insert into notifications (recipient_id, actor_id, movie_id, kind)
    select f.follower_id, auth.uid(), p_movie_id, 'friend_loved'
    from follows f
    join rankings r on r.user_id = f.follower_id and r.movie_id = p_movie_id
    where f.following_id = auth.uid()          -- recipients follow the rater
      and f.follower_id <> auth.uid()
      and r.score >= 8.5                        -- they "really like" it
      and not exists (                          -- de-dupe within 30 days
        select 1 from notifications n
        where n.recipient_id = f.follower_id
          and n.actor_id = auth.uid()
          and n.movie_id = p_movie_id
          and n.kind = 'friend_loved'
          and n.created_at > now() - interval '30 days'
      );
end $$;

revoke all on function public.notify_friends_of_rating(integer) from public, anon;
grant execute on function public.notify_friends_of_rating(integer) to authenticated;
