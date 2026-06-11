-- "What people think → Everyone": every rating of a movie that has a
-- public note, from any member whose profile is visible (can_view =
-- self, public profile, or followed). Includes the 'ranked' feed event
-- so hearts and comments reuse the existing likes/comments tables.
create or replace function public.movie_public_notes(p_movie_id int)
returns table (
  user_id uuid,
  username text,
  display_name text,
  avatar_url text,
  score double precision,
  note text,
  ranked_at timestamptz,
  event_id uuid,
  like_count int,
  comment_count int,
  liked_by_me boolean
)
language sql stable security definer
set search_path = public
as $$
  select r.user_id,
         p.username, p.display_name, p.avatar_url,
         r.score::double precision,
         n.body as note,
         r.created_at as ranked_at,
         e.id as event_id,
         coalesce(l.n, 0)::int as like_count,
         coalesce(c.n, 0)::int as comment_count,
         coalesce(ml.liked, false) as liked_by_me
  from rankings r
  join notes n
    on n.user_id = r.user_id and n.movie_id = r.movie_id and not n.is_private
  join profiles p on p.id = r.user_id
  left join lateral (
    select fe.id from feed_events fe
    where fe.user_id = r.user_id and fe.movie_id = r.movie_id
      and fe.event_type = 'ranked'
    order by fe.created_at desc limit 1
  ) e on true
  left join lateral (select count(*) as n from likes where event_id = e.id) l on true
  left join lateral (select count(*) as n from comments where event_id = e.id) c on true
  left join lateral (
    select true as liked from likes
    where event_id = e.id and user_id = auth.uid()
  ) ml on true
  where r.movie_id = p_movie_id
    and can_view(r.user_id)
  order by coalesce(l.n, 0) desc, r.created_at desc
  limit 50;
$$;

revoke execute on function public.movie_public_notes(int) from public, anon;
grant execute on function public.movie_public_notes(int) to authenticated;
