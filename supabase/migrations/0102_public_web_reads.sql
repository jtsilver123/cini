-- 0102_public_web_reads.sql
-- Read-only, anon-callable functions powering the public web layer
-- (trycini.com/u and /l — see docs/WEB_PLAN.md). Until now nothing was readable
-- by the anon role (every table RLS is `to authenticated`), so a logged-out web
-- visitor saw nothing. These three SECURITY DEFINER functions expose ONLY the
-- public slice: content whose owner has is_private = false (and, for lists, the
-- list's own is_private = false). That's exactly the public half of can_view(),
-- minus the follow branch (anon has no identity). No private data ever leaves,
-- and there are no write paths. JSON return shapes keep the static web JS simple.

-- A public member's profile header + counts + social handles. Returns NULL when
-- the username doesn't exist OR the account is private — the page shows the same
-- "not available" either way, never confirming a private account's existence.
create or replace function public.public_profile(p_username text)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'username',      p.username,
    'display_name',  p.display_name,
    'avatar_url',    p.avatar_url,
    'bio',           p.bio,
    'member_since',  p.member_since,
    'streak_weeks',  p.streak_weeks,
    'instagram',     p.instagram_handle,
    'tiktok',        p.tiktok_handle,
    'x',             p.x_handle,
    'letterboxd',    p.letterboxd_handle,
    'ranked_count',  (select count(*) from rankings r where r.user_id = p.id),
    'list_count',    (select count(*) from custom_lists cl
                      where cl.user_id = p.id and not cl.is_private)
  )
  from profiles p
  where lower(p.username) = lower(p_username)
    and not p.is_private;
$$;
revoke all on function public.public_profile(text) from public;
grant execute on function public.public_profile(text) to anon, authenticated;

-- A public member's ranked titles (highest first), joined to movie metadata.
-- Same is_private gate. Empty array when private/not found.
create or replace function public.public_rankings(p_username text, p_limit int default 250)
returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(s.j order by s.sc desc, s.pos asc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'movie_id',     r.movie_id,
             'media_kind',   m.media_kind,
             'title',        m.title,
             'poster_path',  m.poster_path,
             'release_year', m.release_year,
             'bucket',       r.bucket,
             'score',        r.score
           ) as j,
           r.score as sc, r.position as pos
    from rankings r
    join profiles p on p.id = r.user_id
    join movies m on m.tmdb_id = r.movie_id
    where lower(p.username) = lower(p_username)
      and not p.is_private
    order by r.score desc, r.position asc
    limit greatest(1, least(p_limit, 1000))
  ) s;
$$;
revoke all on function public.public_rankings(text, int) from public;
grant execute on function public.public_rankings(text, int) to anon, authenticated;

-- A public custom list: header + owner + items, ordered as curated. Returns NULL
-- unless BOTH the list is public AND its owner is public.
create or replace function public.public_list(p_list_id uuid)
returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id',         cl.id,
    'name',       cl.name,
    'media_kind', cl.media_kind,
    'created_at', cl.created_at,
    'owner', jsonb_build_object(
      'username',     p.username,
      'display_name', p.display_name,
      'avatar_url',   p.avatar_url
    ),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'movie_id',     m.tmdb_id,
               'media_kind',   m.media_kind,
               'title',        m.title,
               'poster_path',  m.poster_path,
               'release_year', m.release_year
             ) order by cli.position asc, cli.created_at asc)
      from custom_list_items cli
      join movies m on m.tmdb_id = cli.movie_id
      where cli.list_id = cl.id
    ), '[]'::jsonb)
  )
  from custom_lists cl
  join profiles p on p.id = cl.user_id
  where cl.id = p_list_id
    and not cl.is_private
    and not p.is_private;
$$;
revoke all on function public.public_list(uuid) from public;
grant execute on function public.public_list(uuid) to anon, authenticated;
