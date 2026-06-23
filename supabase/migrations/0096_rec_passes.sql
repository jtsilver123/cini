-- Passing a card in Recs is a taste signal, not just a local hide: record it so
-- the personalized recommender (recs_for_user, which feeds the Swipe deck and
-- Ask Cini) stops surfacing it — durably and across devices. Undo removes it.

create table if not exists public.rec_passes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  movie_id integer not null,
  created_at timestamptz not null default now(),
  primary key (user_id, movie_id)
);

alter table public.rec_passes enable row level security;

drop policy if exists "rec_passes_own" on public.rec_passes;
create policy "rec_passes_own" on public.rec_passes
  for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

create or replace function public.pass_rec(p_movie_id integer)
returns void language sql security definer set search_path = public as $$
  insert into rec_passes (user_id, movie_id) values (auth.uid(), p_movie_id)
  on conflict do nothing;
$$;
revoke all on function public.pass_rec(integer) from public, anon;
grant execute on function public.pass_rec(integer) to authenticated;

create or replace function public.unpass_rec(p_movie_id integer)
returns void language sql security definer set search_path = public as $$
  delete from rec_passes where user_id = auth.uid() and movie_id = p_movie_id;
$$;
revoke all on function public.unpass_rec(integer) from public, anon;
grant execute on function public.unpass_rec(integer) to authenticated;

-- Recreate recs_for_user (verbatim from 0032) with one change: passed titles are
-- folded into `my_movies`, so they're excluded from candidates and the final
-- result just like ranked / watchlisted titles.
create or replace function public.recs_for_user(p_limit int default 30)
returns table(movie_id int, rec_score numeric, friend_count bigint, top_friend_username text)
language sql stable security definer
set search_path to 'public'
as $$
with my_movies as (
    select movie_id from rankings where user_id = auth.uid()
    union
    select movie_id from watchlist where user_id = auth.uid()
    union
    select movie_id from rec_passes where user_id = auth.uid()
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
