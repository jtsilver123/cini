-- 0046: every user gets a UNIQUE rank — no ties.
--
-- global_rank returned `1 + count(users with more rankings)`, so anyone with
-- the same count shared a rank (and every zero-ranking user tied). Rank ALL
-- profiles with row_number() and a deterministic tiebreaker so each user
-- always has a different rank: most watched first, then earliest member, then
-- id as the absolute backstop. leaderboard gets the same tiebreaker so its
-- order (and the positions shown) is stable and unique too.

create or replace function public.global_rank(p_user uuid)
returns bigint language sql stable set search_path = public as $$
    with ranked as (
        select p.id,
               row_number() over (
                   order by coalesce(c.n, 0) desc, p.created_at asc, p.id
               ) as rk
        from profiles p
        left join (select user_id, count(*) as n from rankings group by user_id) c
            on c.user_id = p.id
    )
    select coalesce((select rk from ranked where id = p_user), 1);
$$;

create or replace function public.leaderboard(
    p_metric text default 'watched',
    p_school text default null,
    p_genre text default null,
    p_limit integer default 100
) returns table(user_id uuid, username text, avatar_url text, school text, value bigint, match_pct numeric)
language sql stable security definer set search_path = public as $$
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
    order by m.value desc, p.created_at asc, p.id
    limit p_limit;
$$;
