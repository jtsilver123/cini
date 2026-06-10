-- RPCs, triggers, and views that keep ranking state transactional and
-- power streaks, feed events, taste match, and leaderboards.

-- ---------------------------------------------------------------------------
-- New-user bootstrap: create a profile row on signup.
-- ---------------------------------------------------------------------------
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into public.profiles (id, username, display_name)
    values (
        new.id,
        coalesce(new.raw_user_meta_data ->> 'username',
                 'user_' || substr(new.id::text, 1, 8)),
        coalesce(new.raw_user_meta_data ->> 'display_name', '')
    )
    on conflict (id) do nothing;
    return new;
end $$;

create trigger on_auth_user_created
    after insert on auth.users
    for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Movie cache upsert (clients call this after a TMDB fetch).
-- ---------------------------------------------------------------------------
create or replace function public.cache_movie(
    p_tmdb_id integer, p_media_kind text, p_title text, p_release_year smallint,
    p_poster_path text, p_backdrop_path text, p_genres text[],
    p_certification text, p_runtime_minutes integer, p_director text, p_overview text
) returns void
language sql security definer set search_path = public as $$
    insert into movies (tmdb_id, media_kind, title, release_year, poster_path,
                        backdrop_path, genres, certification, runtime_minutes,
                        director, overview, cached_at)
    values (p_tmdb_id, p_media_kind, p_title, p_release_year, p_poster_path,
            p_backdrop_path, p_genres, p_certification, p_runtime_minutes,
            p_director, p_overview, now())
    on conflict (tmdb_id) do update set
        title = excluded.title, release_year = excluded.release_year,
        poster_path = excluded.poster_path, backdrop_path = excluded.backdrop_path,
        genres = excluded.genres, certification = excluded.certification,
        runtime_minutes = excluded.runtime_minutes, director = excluded.director,
        overview = excluded.overview, cached_at = now();
$$;

-- ---------------------------------------------------------------------------
-- Bucket rescore: scores derive from position; recompute the whole bucket.
-- Bands mirror RankingEngine.ScoreCalculator exactly.
-- ---------------------------------------------------------------------------
create or replace function public.rescore_bucket(p_user uuid, p_bucket text) returns void
language plpgsql as $$
declare
    v_hi numeric; v_lo numeric; v_n integer;
begin
    select case p_bucket when 'loved' then 10.0 when 'fine' then 6.6 else 3.3 end,
           case p_bucket when 'loved' then 6.7  when 'fine' then 3.4 else 0.0 end
    into v_hi, v_lo;

    select count(*) into v_n from rankings where user_id = p_user and bucket = p_bucket;
    if v_n = 0 then return; end if;

    update rankings r set score = round(
        case when v_n = 1 then v_hi
             else v_hi - (v_hi - v_lo) * r.position / (v_n - 1) end, 1)
    where r.user_id = p_user and r.bucket = p_bucket;
end $$;

-- ---------------------------------------------------------------------------
-- Atomic ranking insertion. Shifts positions, rescores the bucket, bumps the
-- streak, removes any watchlist row, and emits feed events — one transaction.
-- Handles re-ranking (existing row moves, possibly across buckets).
-- ---------------------------------------------------------------------------
create or replace function public.rank_insert(
    p_movie_id integer,
    p_bucket text,
    p_position integer,
    p_watch_date date default null
) returns public.rankings
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_old rankings%rowtype;
    v_row rankings%rowtype;
    v_count integer;
    v_pos integer;
    v_week date := date_trunc('week', now())::date;
    v_was_new boolean := true;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    if p_bucket not in ('loved', 'fine', 'disliked') then
        raise exception 'invalid bucket %', p_bucket;
    end if;

    -- Serialize concurrent inserts for this user's list.
    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    -- Re-ranking: pull the old row out and close its gap first.
    select * into v_old from rankings where user_id = v_user and movie_id = p_movie_id;
    if found then
        v_was_new := false;
        delete from rankings where id = v_old.id;
        update rankings set position = position - 1
        where user_id = v_user and bucket = v_old.bucket and position > v_old.position;
        if v_old.bucket <> p_bucket then
            perform rescore_bucket(v_user, v_old.bucket);
        end if;
    end if;

    select count(*) into v_count from rankings where user_id = v_user and bucket = p_bucket;
    v_pos := least(greatest(p_position, 0), v_count);

    update rankings set position = position + 1
    where user_id = v_user and bucket = p_bucket and position >= v_pos;

    insert into rankings (user_id, movie_id, bucket, position, score, watch_date, watched_with)
    values (v_user, p_movie_id, p_bucket, v_pos, 0,
            coalesce(p_watch_date, v_old.watch_date),
            coalesce(v_old.watched_with, '{}'))
    returning * into v_row;

    perform rescore_bucket(v_user, p_bucket);

    -- Logging a movie clears it from the watchlist.
    delete from watchlist where user_id = v_user and movie_id = p_movie_id;

    -- Streak: one log per ISO week keeps it alive.
    update profiles p set
        streak_weeks = case
            when p.last_logged_week = v_week then p.streak_weeks
            when p.last_logged_week = v_week - 7 then p.streak_weeks + 1
            else 1 end,
        last_logged_week = v_week
    where p.id = v_user;

    if v_was_new then
        insert into feed_events (user_id, event_type, movie_id, payload)
        select v_user, 'ranked', p_movie_id,
               jsonb_build_object('score', r.score, 'bucket', p_bucket)
        from rankings r where r.id = v_row.id;

        -- Notify followers who have this movie on their watchlist.
        insert into notifications (recipient_id, actor_id, kind, movie_id)
        select w.user_id, v_user, 'friend_ranked_watchlist_movie', p_movie_id
        from watchlist w
        join follows f on f.follower_id = w.user_id and f.following_id = v_user
        where w.movie_id = p_movie_id;
    end if;

    select * into v_row from rankings where id = v_row.id;
    return v_row;
end $$;

-- ---------------------------------------------------------------------------
-- Atomic removal (also used by "Rank again" client flows that abort).
-- ---------------------------------------------------------------------------
create or replace function public.rank_remove(p_movie_id integer) returns void
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_old rankings%rowtype;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    select * into v_old from rankings where user_id = v_user and movie_id = p_movie_id;
    if not found then return; end if;

    delete from rankings where id = v_old.id;
    update rankings set position = position - 1
    where user_id = v_user and bucket = v_old.bucket and position > v_old.position;
    perform rescore_bucket(v_user, v_old.bucket);
end $$;

-- ---------------------------------------------------------------------------
-- Watchlist toggle with feed event.
-- ---------------------------------------------------------------------------
create or replace function public.watchlist_toggle(p_movie_id integer) returns boolean
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_deleted integer;
begin
    delete from watchlist where user_id = v_user and movie_id = p_movie_id;
    get diagnostics v_deleted = row_count;
    if v_deleted > 0 then return false; end if;

    insert into watchlist (user_id, movie_id) values (v_user, p_movie_id);
    insert into feed_events (user_id, event_type, movie_id)
    values (v_user, 'watchlisted', p_movie_id);
    return true;
end $$;

-- ---------------------------------------------------------------------------
-- Community + friend aggregates for the movie detail page.
-- ---------------------------------------------------------------------------
create or replace view public.movie_community_scores as
select movie_id,
       round(avg(score), 1) as avg_score,
       count(*) as rating_count
from public.rankings
group by movie_id;

create or replace function public.movie_friend_scores(p_movie_id integer)
returns table (user_id uuid, username text, display_name text, avatar_url text,
               score numeric, note text, ranked_at timestamptz)
language sql stable security definer set search_path = public as $$
    select r.user_id, p.username, p.display_name, p.avatar_url, r.score,
           (select n.body from notes n
            where n.user_id = r.user_id and n.movie_id = r.movie_id and not n.is_private
            limit 1),
           r.created_at
    from rankings r
    join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
    join profiles p on p.id = r.user_id
    where r.movie_id = p_movie_id
    order by r.created_at desc;
$$;

create or replace function public.movie_score_histogram(p_movie_id integer)
returns table (bucket_floor integer, n bigint)
language sql stable set search_path = public as $$
    select floor(score)::integer, count(*)
    from rankings where movie_id = p_movie_id
    group by 1 order by 1;
$$;

-- ---------------------------------------------------------------------------
-- Taste match: Spearman rank correlation over commonly-ranked titles,
-- mapped to a 0–100 percentage. Run nightly (pg_cron) and on-demand.
-- ---------------------------------------------------------------------------
create or replace function public.compute_taste_match(u1 uuid, u2 uuid)
returns numeric
language plpgsql stable set search_path = public as $$
declare
    v_rho numeric;
    v_n integer;
begin
    select corr(a.rk, b.rk), count(*) into v_rho, v_n
    from (select movie_id, rank() over (order by bucket, position) as rk
          from rankings where user_id = u1) a
    join (select movie_id, rank() over (order by bucket, position) as rk
          from rankings where user_id = u2) b using (movie_id);

    if v_n < 3 or v_rho is null then return null; end if;
    return round((v_rho + 1) / 2 * 100, 2);   -- [-1,1] → [0,100]
end $$;

create or replace function public.refresh_taste_matches() returns void
language plpgsql security definer set search_path = public as $$
declare
    pair record;
    v_pct numeric;
begin
    for pair in
        select distinct least(f.follower_id, f.following_id) as a,
                        greatest(f.follower_id, f.following_id) as b
        from follows f
    loop
        v_pct := compute_taste_match(pair.a, pair.b);
        if v_pct is not null then
            insert into taste_matches (user_a, user_b, pct, sample_size, computed_at)
            values (pair.a, pair.b, v_pct,
                    (select count(*) from rankings r1
                     join rankings r2 using (movie_id)
                     where r1.user_id = pair.a and r2.user_id = pair.b),
                    now())
            on conflict (user_a, user_b) do update
                set pct = excluded.pct, sample_size = excluded.sample_size,
                    computed_at = now();
        end if;
    end loop;
end $$;

-- Nightly refresh if pg_cron is enabled on the project:
--   select cron.schedule('taste-match-nightly', '0 9 * * *',
--                        $$select public.refresh_taste_matches()$$);

-- ---------------------------------------------------------------------------
-- Leaderboard: watched / influence / notes counts, filterable by school.
-- "Influence" = how many times your 'ranked' events converted into a
-- watchlist add of the same movie by a follower within 30 days.
-- ---------------------------------------------------------------------------
create or replace function public.leaderboard(
    p_metric text default 'watched',
    p_school text default null,
    p_genre text default null,
    p_limit integer default 100
) returns table (user_id uuid, username text, avatar_url text, school text,
                 value bigint, match_pct numeric)
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
    order by m.value desc
    limit p_limit;
$$;

-- Global rank by watched count, for "#Rank on Cini".
create or replace function public.global_rank(p_user uuid) returns bigint
language sql stable set search_path = public as $$
    with counts as (
        select user_id, count(*) as n from rankings group by user_id
    )
    select coalesce(
        (select 1 + count(*) from counts
         where n > coalesce((select n from counts where user_id = p_user), 0)),
        1);
$$;

-- ---------------------------------------------------------------------------
-- Invite redemption: auto-follow both ways' inviter on signup.
-- ---------------------------------------------------------------------------
create or replace function public.redeem_invite(p_code text) returns void
language plpgsql security definer set search_path = public as $$
declare
    v_inviter uuid;
begin
    update invites set invitee_id = auth.uid(), redeemed_at = now()
    where code = p_code and redeemed_at is null
    returning inviter_id into v_inviter;
    if v_inviter is not null and v_inviter <> auth.uid() then
        insert into follows (follower_id, following_id)
        values (auth.uid(), v_inviter) on conflict do nothing;
    end if;
end $$;

-- ---------------------------------------------------------------------------
-- Seed built-in labels
-- ---------------------------------------------------------------------------
insert into public.labels (owner_id, name) values
    (null, 'Date Night'), (null, 'Plane Movie'), (null, 'Mindblower'),
    (null, 'Slow Burn'), (null, 'Rewatchable'), (null, 'Comfort Watch'),
    (null, 'Tearjerker'), (null, 'Popcorn Flick')
on conflict do nothing;
