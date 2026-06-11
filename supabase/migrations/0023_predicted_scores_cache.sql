-- Nightly-materialized Rec Scores: long watchlists shouldn't recompute
-- the full blend on every open. predicted_scores() serves fresh cache
-- rows and computes only the misses live. Cron: 'predicted-cache-nightly'
-- at 09:20 UTC, after taste-match-nightly (09:00) so it folds in fresh
-- match weights. (Applied to prod via MCP on 2026-06-11.)

create table public.predicted_cache (
  user_id uuid not null references public.profiles(id) on delete cascade,
  movie_id integer not null,
  predicted numeric not null,
  computed_at timestamptz not null default now(),
  primary key (user_id, movie_id)
);

alter table public.predicted_cache enable row level security;
create policy predicted_cache_select on public.predicted_cache
  for select using (user_id = auth.uid());

-- The blend, parameterized by user (was inlined with auth.uid()).
-- Body identical to the original predicted_scores formula.
create or replace function public.predicted_scores_for(p_user uuid, p_movie_ids integer[])
returns table(movie_id integer, predicted numeric)
language sql stable security definer
set search_path to 'public'
as $$
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
             + 0.2 * coalesce(cm.cscore, 6.5)
       else
           0.6 * gs.gscore + 0.4 * coalesce(cm.cscore, 6.5)
       end)::numeric, 1) as predicted
from candidates c
join genre_score gs on gs.movie_id = c.movie_id
left join friend_agg fa on fa.movie_id = c.movie_id
left join community cm on cm.movie_id = c.movie_id;
$$;

revoke execute on function public.predicted_scores_for(uuid, integer[]) from public, anon, authenticated;

-- Same signature as before; cache-first, compute only the misses.
create or replace function public.predicted_scores(p_movie_ids integer[])
returns table(movie_id integer, predicted numeric)
language sql stable security definer
set search_path to 'public'
as $$
  with cached as (
    select pc.movie_id, pc.predicted
    from predicted_cache pc
    where pc.user_id = auth.uid()
      and pc.movie_id = any(p_movie_ids)
      and pc.computed_at > now() - interval '36 hours'
  )
  select * from cached
  union all
  select f.movie_id, f.predicted
  from predicted_scores_for(
      auth.uid(),
      (select coalesce(array_agg(x), '{}'::integer[])
       from unnest(p_movie_ids) x
       where x not in (select c.movie_id from cached c))) f;
$$;

-- Nightly refresh of every member's watchlist scores.
create or replace function public.refresh_predicted_cache()
returns void
language plpgsql security definer
set search_path to 'public'
as $$
declare u record;
begin
  for u in select distinct user_id from watchlist loop
    insert into predicted_cache (user_id, movie_id, predicted, computed_at)
    select u.user_id, ps.movie_id, ps.predicted, now()
    from predicted_scores_for(
        u.user_id,
        (select array_agg(w.movie_id) from watchlist w where w.user_id = u.user_id)) ps
    on conflict (user_id, movie_id) do update
      set predicted = excluded.predicted, computed_at = excluded.computed_at;
  end loop;
  -- Rows for titles dropped from watchlists age out.
  delete from predicted_cache where computed_at < now() - interval '7 days';
end $$;

revoke execute on function public.refresh_predicted_cache() from public, anon, authenticated;

select cron.schedule('predicted-cache-nightly', '20 9 * * *',
                     'select public.refresh_predicted_cache()');
