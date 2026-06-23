-- 0099_recs_taste_v3.sql
-- Taste model v3 for the Recs page (recs_for_user). The v2 blend only used your
-- ratings' genre averages + friends + community, and treated bookmarks/passes as
-- mere exclusions. v3 learns from every signal and gets sharper the more we know:
--
--  • Genre taste is now RELATIVE to your own baseline (your average rating) and
--    CONFIDENCE-SHRUNK, so a genre you've rated once doesn't dominate, and a user
--    who rates everything high doesn't look like they love every genre.
--  • BOOKMARKS feed taste as a mild positive ("I want to watch this"), and
--    PASSES as a negative ("not for me") — both via the same genre-deviation pool.
--  • DIRECTOR affinity is added (a Nolan fan gets more Nolan), shrunk like genres.
--  • The blend is ADAPTIVE: with little data, the community average leads; as you
--    rank more, your personal taste takes over (personal weight = n/(n+15)).
--    Friends (titles they loved, weighted by taste match) keep a steady share.
--
-- Return shape is unchanged, so the app/Ask Cini decode exactly as before.
create or replace function public.recs_for_user(p_limit int default 30)
returns table(movie_id int, rec_score numeric, friend_count bigint, top_friend_username text)
language sql stable security definer
set search_path to 'public'
as $$
with
my_rank as (
    select movie_id, score from rankings where user_id = auth.uid()
),
my_stats as (
    select coalesce(avg(score), 6.5) as mu, count(*)::int as n from my_rank
),
-- Everything already in your world is off the table as a recommendation.
my_movies as (
    select movie_id from my_rank
    union select movie_id from watchlist  where user_id = auth.uid()
    union select movie_id from rec_passes where user_id = auth.uid()
),
-- Per-genre deviation from your baseline, pooling three signals at different
-- strengths: ratings (full weight, real deviation), bookmarks (mild positive),
-- passes (stronger negative). Constants are deliberately conservative.
genre_signal as (
    select g.genre, (r.score - st.mu) as dev, 1.0::numeric as wt
    from my_rank r cross join my_stats st
    join movies m on m.tmdb_id = r.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    union all
    select g.genre, 0.7::numeric, 0.4::numeric
    from watchlist w
    join movies m on m.tmdb_id = w.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where w.user_id = auth.uid()
    union all
    select g.genre, -1.5::numeric, 0.6::numeric
    from rec_passes p
    join movies m on m.tmdb_id = p.movie_id
    cross join lateral unnest(m.genres) as g(genre)
    where p.user_id = auth.uid()
),
-- Shrink toward 0 (neutral) by total evidence, so thin genres stay cautious.
genre_dev as (
    select genre, sum(wt * dev) / (sum(wt) + 4) as dev
    from genre_signal group by genre
),
-- Director affinity from ratings only, shrunk the same way.
dir_dev as (
    select m.director, sum(r.score - st.mu) / (count(*) + 3) as dev
    from my_rank r cross join my_stats st
    join movies m on m.tmdb_id = r.movie_id
    where m.director is not null
    group by m.director
),
-- Bayesian community average (prior of 6.5 with weight 5).
community as (
    select r.movie_id, (sum(r.score) + 6.5 * 5) / (count(*) + 5) as cscore
    from rankings r group by r.movie_id
),
-- Friends who loved it (>= 6.7), weighted by taste match (default 0.5 unknown).
friend_ranks as (
    select r.movie_id, r.score, p.username,
           coalesce((select tm.pct / 100.0 from taste_matches tm
                     where tm.user_a = least(auth.uid(), r.user_id)
                       and tm.user_b = greatest(auth.uid(), r.user_id)), 0.5) as mw
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
    join profiles p on p.id = r.user_id
    where r.score >= 6.7
      and not_blocked(r.user_id)
      and r.movie_id not in (select movie_id from my_movies)
),
friend_agg as (
    select fr.movie_id,
           sum(fr.score * fr.mw) / sum(fr.mw) as wavg,
           count(*) as cnt,
           (array_agg(fr.username order by fr.score * fr.mw desc))[1] as top_friend
    from friend_ranks fr group by fr.movie_id
),
candidates as (
    select movie_id from friend_agg
    union
    select m.tmdb_id from movies m
    where exists (select 1 from rankings r where r.movie_id = m.tmdb_id)
),
-- Personal score for each candidate: your baseline nudged by the genres and
-- director, clamped to a valid rating.
cand_personal as (
    select c.movie_id,
           coalesce(avg(gd.dev), 0) as gdev,
           coalesce(max(dd.dev), 0) as ddev
    from candidates c
    join movies m on m.tmdb_id = c.movie_id
    left join lateral unnest(m.genres) as g(genre) on true
    left join genre_dev gd on gd.genre = g.genre
    left join dir_dev  dd on dd.director = m.director
    group by c.movie_id
),
-- Personal confidence grows with how much you've ranked.
uw as (
    select mu, (n::numeric / (n + 15)) as pc from my_stats
)
select c.movie_id,
       round((
             (0.60 * uw.pc)
                 * least(10, greatest(0, uw.mu + cp.gdev + 0.5 * cp.ddev))
           + (case when fa.movie_id is not null then 0.30 else 0 end)
                 * least(10, fa.wavg * (1 + least(fa.cnt - 1, 3) * 0.08))
           + (1 - 0.60 * uw.pc - (case when fa.movie_id is not null then 0.30 else 0 end))
                 * cm.cscore
       )::numeric, 1) as rec_score,
       coalesce(fa.cnt, 0) as friend_count,
       fa.top_friend as top_friend_username
from candidates c
join cand_personal cp on cp.movie_id = c.movie_id
join community cm on cm.movie_id = c.movie_id
left join friend_agg fa on fa.movie_id = c.movie_id
cross join uw
where c.movie_id not in (select movie_id from my_movies)
order by rec_score desc, coalesce(fa.cnt, 0) desc
limit p_limit;
$$;
revoke execute on function public.recs_for_user(int) from public, anon;
grant execute on function public.recs_for_user(int) to authenticated;
