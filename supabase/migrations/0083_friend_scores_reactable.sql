-- CIN-40: the "What people think → Friends" wall should be reactable (like the
-- feed) and include your OWN ranking. Extend movie_friend_scores to also return
-- the ranking's feed event + like/comment counts + liked-by-me, and to include
-- the caller's own row (sorted first). Return shape changes, so drop first.
drop function if exists public.movie_friend_scores(integer);

create or replace function public.movie_friend_scores(p_movie_id integer)
returns table(
    user_id uuid, username text, display_name text, avatar_url text,
    score numeric, note text, contains_spoilers boolean, ranked_at timestamptz,
    event_id uuid, like_count integer, comment_count integer,
    liked_by_me boolean, is_self boolean)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select r.user_id, p.username, p.display_name, p.avatar_url, r.score,
           n.body, coalesce(n.contains_spoilers, false), r.created_at,
           e.id,
           coalesce((select count(*) from likes l where l.event_id = e.id), 0)::int,
           coalesce((select count(*) from comments c where c.event_id = e.id), 0)::int,
           exists(select 1 from likes l where l.event_id = e.id and l.user_id = auth.uid()),
           r.user_id = auth.uid()
    from rankings r
    join profiles p on p.id = r.user_id
    left join lateral (
      select body, contains_spoilers from notes n
      where n.user_id = r.user_id and n.movie_id = r.movie_id and not n.is_private
      limit 1
    ) n on true
    left join lateral (
      select id from feed_events ev
      where ev.user_id = r.user_id and ev.movie_id = r.movie_id
        and ev.event_type = 'ranked'
      order by ev.created_at desc
      limit 1
    ) e on true
    where r.movie_id = p_movie_id
      and not_blocked(r.user_id)
      and (r.user_id = auth.uid()
           or exists (select 1 from follows f
                      where f.following_id = r.user_id and f.follower_id = auth.uid()))
    order by (r.user_id = auth.uid()) desc, r.created_at desc;
$function$;

grant execute on function public.movie_friend_scores(integer) to authenticated;
