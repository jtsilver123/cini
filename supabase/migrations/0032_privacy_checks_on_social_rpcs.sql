-- Block/privacy enforcement on the social RPCs (the audit found these
-- leaked): leaderboard and suggestions now respect can_view (private
-- profiles' stats stay private; blocked pairs vanish), search and
-- contact-matching hide blocked members (privates stay FINDABLE — you
-- must be able to find someone to request a follow), and recs no longer
-- derive from people in a block pair.

create or replace function public.leaderboard(
  p_metric text default 'watched', p_school text default null,
  p_genre text default null, p_limit int default 100)
returns table(user_id uuid, username text, avatar_url text, school text, value bigint, match_pct numeric)
language sql stable security definer
set search_path to 'public'
as $$
    with metric as (
        select p.id,
            case p_metric
                when 'watched' then (
                    select count(*) from rankings r
                    join movies m on m.tmdb_id = r.movie_id
                    where r.user_id = p.id
                      and (p_genre is null or p_genre = any (m.genres)))
                when 'notes' then (
                    select count(*) from notes n
                    where n.user_id = p.id and not n.is_private)
                when 'influence' then (
                    select count(*) from feed_events e
                    join follows f on f.following_id = e.user_id
                    join watchlist w on w.user_id = f.follower_id
                                    and w.movie_id = e.movie_id
                                    and w.created_at between e.created_at
                                                         and e.created_at + interval '30 days'
                    where e.user_id = p.id and e.event_type = 'ranked')
                else 0
            end as value
        from profiles p
        where p_school is null or p.school = p_school
    )
    select m.id, p.username, p.avatar_url, p.school, m.value,
           (select tm.pct from taste_matches tm
            where (tm.user_a = least(m.id, auth.uid()) and tm.user_b = greatest(m.id, auth.uid())))
    from metric m
    join profiles p on p.id = m.id
    where m.value > 0
      and can_view(m.id)
    order by m.value desc
    limit p_limit;
$$;
revoke execute on function public.leaderboard(text, text, text, int) from public, anon;
grant execute on function public.leaderboard(text, text, text, int) to authenticated;

create or replace function public.search_members(p_query text)
returns setof profiles
language sql stable
set search_path to 'public', 'extensions'
as $$
  select *
  from profiles
  where not_blocked(profiles.id)
    and (username ilike '%' || p_query || '%'
     or display_name ilike '%' || p_query || '%'
     or username % p_query
     or coalesce(display_name, '') % p_query)
  order by greatest(
    similarity(username, p_query),
    similarity(coalesce(display_name, ''), p_query)
  ) desc
  limit 25;
$$;
revoke execute on function public.search_members(text) from public, anon;
grant execute on function public.search_members(text) to authenticated;

create or replace function public.suggested_members(p_limit int default 25)
returns table(id uuid, username text, display_name text, avatar_url text, match_pct numeric, watched bigint)
language sql stable security definer
set search_path to 'public'
as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         tm.pct as match_pct,
         (select count(*) from rankings r where r.user_id = p.id) as watched
  from profiles p
  left join taste_matches tm
    on (tm.user_a = auth.uid() and tm.user_b = p.id)
    or (tm.user_b = auth.uid() and tm.user_a = p.id)
  where p.id <> auth.uid()
    and can_view(p.id)
    and not exists (
      select 1 from follows f
      where f.follower_id = auth.uid() and f.following_id = p.id
    )
  order by tm.pct desc nulls last,
           (select count(*) from rankings r where r.user_id = p.id) desc
  limit p_limit;
$$;
revoke execute on function public.suggested_members(int) from public, anon;
grant execute on function public.suggested_members(int) to authenticated;

create or replace function public.members_from_emails(p_emails text[])
returns table(id uuid, username text, display_name text, avatar_url text)
language sql stable security definer
set search_path to 'public'
as $$
  select p.id, p.username, p.display_name, p.avatar_url
  from auth.users u
  join profiles p on p.id = u.id
  where lower(u.email) in (select lower(e) from unnest(p_emails) e)
    and p.id <> auth.uid()
    and not_blocked(p.id)
  limit 100;
$$;
revoke execute on function public.members_from_emails(text[]) from public, anon;
grant execute on function public.members_from_emails(text[]) to authenticated;

create or replace function public.recs_for_user(p_limit int default 30)
returns table(movie_id int, rec_score numeric, friend_count bigint, top_friend_username text)
language sql stable security definer
set search_path to 'public'
as $$
with my_movies as (
    select movie_id from rankings where user_id = auth.uid()
    union
    select movie_id from watchlist where user_id = auth.uid()
),
my_genre_affinity as (
    select g.genre, avg(r.score) as affinity
    from rankings r
    join movies m on m.tmdb_id = r.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where r.user_id = auth.uid()
    group by g.genre
),
community as (
    select r.movie_id,
           (sum(r.score) + 6.5 * 5) / (count(*) + 5) as cscore
    from rankings r
    group by r.movie_id
),
friend_ranks as (
    select r.movie_id, r.score, p.username,
           coalesce(
               (select tm.pct / 100.0 from taste_matches tm
                where tm.user_a = least(auth.uid(), r.user_id)
                  and tm.user_b = greatest(auth.uid(), r.user_id)),
               0.5) as match_weight
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
    join profiles p on p.id = r.user_id
    where r.score >= 6.7
      and not_blocked(r.user_id)
      and r.movie_id not in (select movie_id from my_movies)
),
friend_agg as (
    select fr.movie_id,
           sum(fr.score * fr.match_weight) / sum(fr.match_weight) as wavg,
           count(*) as cnt,
           (array_agg(fr.username order by fr.score * fr.match_weight desc))[1] as top_friend
    from friend_ranks fr
    group by fr.movie_id
),
candidates as (
    select fa.movie_id from friend_agg fa
    union
    select m.tmdb_id from movies m
    where exists (select 1 from rankings r where r.movie_id = m.tmdb_id)
),
genre_score as (
    select c.movie_id, coalesce(avg(ga.affinity), 5.5) as gscore
    from candidates c
    join movies m on m.tmdb_id = c.movie_id
    left join lateral unnest(m.genres) as g(genre) on true
    left join my_genre_affinity ga on ga.genre = g.genre
    group by c.movie_id
)
select c.movie_id,
       round((case when fa.movie_id is not null then
           0.5 * least(10, fa.wavg * (1 + least(fa.cnt - 1, 3) * 0.08))
             + 0.3 * gs.gscore
             + 0.2 * cm.cscore
       else
           0.6 * gs.gscore + 0.4 * cm.cscore
       end)::numeric, 1) as rec_score,
       coalesce(fa.cnt, 0) as friend_count,
       fa.top_friend as top_friend_username
from candidates c
left join friend_agg fa on fa.movie_id = c.movie_id
join genre_score gs on gs.movie_id = c.movie_id
join community cm on cm.movie_id = c.movie_id
where c.movie_id not in (select movie_id from my_movies)
order by rec_score desc, coalesce(fa.cnt, 0) desc
limit p_limit;
$$;
revoke execute on function public.recs_for_user(int) from public, anon;
grant execute on function public.recs_for_user(int) to authenticated;
