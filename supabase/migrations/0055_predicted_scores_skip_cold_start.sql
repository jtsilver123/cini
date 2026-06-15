-- Rec Score cold-start fix.
--
-- predicted_scores_for blends three signals: how friends rated it (weighted by
-- taste match), the user's genre affinity, and the community average. When a
-- user has NO ranking history (no genre affinity) AND the title has no friend
-- or community ratings, every term falls back to its prior and the formula
-- collapses to a constant 0.6*5.5 + 0.4*6.5 = 5.9 for EVERY movie — which looks
-- broken ("why is everything 5.9?").
--
-- Fix: only return a Rec Score when there's at least one real signal (a friend
-- ranked it, the community ranked it, or the user has affinity for one of its
-- genres). With no signal we return no row, so the UI simply hides the badge
-- until there's something to predict from.

create or replace function public.predicted_scores_for(p_user uuid, p_movie_ids integer[])
returns table(movie_id integer, predicted numeric)
language sql
stable security definer
set search_path to 'public'
as $function$
with candidates as (
    select distinct unnest(p_movie_ids) as movie_id
),
my_genre_affinity as (
    select g.genre, avg(r.score) as affinity
    from rankings r
    join movies m on m.tmdb_id = r.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where r.user_id = p_user
    group by g.genre
),
community as (
    select r.movie_id,
           (sum(r.score) + 6.5 * 5) / (count(*) + 5) as cscore
    from rankings r
    where r.movie_id = any(p_movie_ids)
    group by r.movie_id
),
friend_ranks as (
    select r.movie_id, r.score,
           coalesce(
               (select tm.pct / 100.0 from taste_matches tm
                where tm.user_a = least(p_user, r.user_id)
                  and tm.user_b = greatest(p_user, r.user_id)),
               0.5) as match_weight
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = p_user
    where r.movie_id = any(p_movie_ids)
),
friend_agg as (
    select fr.movie_id,
           sum(fr.score * fr.match_weight) / sum(fr.match_weight) as wavg,
           count(*) as cnt
    from friend_ranks fr
    group by fr.movie_id
),
genre_score as (
    select c.movie_id,
           coalesce(avg(ga.affinity), 5.5) as gscore,
           count(ga.affinity) as matched      -- genres of this title the user has affinity for
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
             + 0.2 * coalesce(cm.cscore, 6.5)
       else
           0.6 * gs.gscore + 0.4 * coalesce(cm.cscore, 6.5)
       end)::numeric, 1) as predicted
from candidates c
join genre_score gs on gs.movie_id = c.movie_id
left join friend_agg fa on fa.movie_id = c.movie_id
left join community cm on cm.movie_id = c.movie_id
-- Skip pure cold-start rows: no friend signal, no community signal, and the
-- user has no affinity for any of this title's genres.
where fa.movie_id is not null
   or cm.movie_id is not null
   or gs.matched > 0;
$function$;
