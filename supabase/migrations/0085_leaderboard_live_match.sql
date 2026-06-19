-- The leaderboard showed a % match only for pairs already in the (sparsely
-- populated) taste_matches cache. Fall back to computing the match live so it
-- shows for everyone you share enough ranked titles with. leaderboard is
-- SECURITY DEFINER, so it may call compute_taste_match (service-role only).
create or replace function public.leaderboard(
    p_metric text default 'watched',
    p_school text default null,
    p_genre text default null,
    p_limit integer default 100)
returns table(user_id uuid, username text, avatar_url text, school text,
              value bigint, match_pct numeric)
language sql
stable
security definer
set search_path to 'public'
as $function$
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
           coalesce(
               (select tm.pct from taste_matches tm
                where tm.user_a = least(m.id, auth.uid())
                  and tm.user_b = greatest(m.id, auth.uid())),
               compute_taste_match(m.id, auth.uid()))
    from metric m
    join profiles p on p.id = m.id
    where m.value > 0
      and can_view(m.id)
    order by m.value desc, p.created_at asc, p.id
    limit p_limit;
$function$;
