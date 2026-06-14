-- 0043: rank movies and TV separately.
--
-- Until now positions and scores were scoped to (user, bucket) only, so a
-- loved movie and a loved TV show shared one ordered list and got compared
-- head-to-head. They are different things — rank each media kind on its own.
-- Positions and scores are now scoped to (user, bucket, media_kind); the
-- media kind is derived from the movies row (no schema change — there is no
-- uniqueness constraint on position to fight).

-- 1) Re-derive existing positions per (user, bucket, media_kind), preserving
--    the current relative order within each kind.
with reranked as (
    select r.id,
           row_number() over (
               partition by r.user_id, r.bucket, m.media_kind
               order by r.position, r.created_at
           ) - 1 as new_position
    from rankings r
    join movies m on m.tmdb_id = r.movie_id
)
update rankings r set position = reranked.new_position
from reranked where reranked.id = r.id;

-- 2) Kind-scoped rescore (same linear band math, within one media kind).
create or replace function public.rescore_bucket(p_user uuid, p_bucket text, p_media_kind text)
returns void language plpgsql as $$
declare v_hi numeric; v_lo numeric; v_n integer;
begin
    select case p_bucket when 'loved' then 10.0 when 'fine' then 6.6 else 3.3 end,
           case p_bucket when 'loved' then 6.7  when 'fine' then 3.4 else 0.0 end
    into v_hi, v_lo;

    select count(*) into v_n
    from rankings r join movies m on m.tmdb_id = r.movie_id
    where r.user_id = p_user and r.bucket = p_bucket and m.media_kind = p_media_kind;
    if v_n = 0 then return; end if;

    update rankings r set score = round(
        case when v_n = 1 then v_hi
             else v_hi - (v_hi - v_lo) * r.position / (v_n - 1) end, 1)
    from movies m
    where m.tmdb_id = r.movie_id and r.user_id = p_user
      and r.bucket = p_bucket and m.media_kind = p_media_kind;
end $$;

-- 3) rank_insert: derive the media kind, scope every position shift and the
--    rescore by it. Signature is unchanged — the client still sends just the
--    bucket + position (position is now within that kind's bucket).
create or replace function public.rank_insert(
    p_movie_id integer,
    p_bucket text,
    p_position integer,
    p_watch_date date default null
) returns public.rankings
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_kind text;
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

    select media_kind into v_kind from movies where tmdb_id = p_movie_id;
    if v_kind is null then raise exception 'unknown movie %', p_movie_id; end if;

    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    -- Re-ranking: pull the old row out and close its gap (same kind).
    select * into v_old from rankings where user_id = v_user and movie_id = p_movie_id;
    if found then
        v_was_new := false;
        delete from rankings where id = v_old.id;
        update rankings r set position = r.position - 1
        from movies m
        where m.tmdb_id = r.movie_id and r.user_id = v_user
          and r.bucket = v_old.bucket and m.media_kind = v_kind
          and r.position > v_old.position;
        if v_old.bucket <> p_bucket then
            perform rescore_bucket(v_user, v_old.bucket, v_kind);
        end if;
    end if;

    select count(*) into v_count
    from rankings r join movies m on m.tmdb_id = r.movie_id
    where r.user_id = v_user and r.bucket = p_bucket and m.media_kind = v_kind;
    v_pos := least(greatest(p_position, 0), v_count);

    update rankings r set position = r.position + 1
    from movies m
    where m.tmdb_id = r.movie_id and r.user_id = v_user
      and r.bucket = p_bucket and m.media_kind = v_kind
      and r.position >= v_pos;

    insert into rankings (user_id, movie_id, bucket, position, score, watch_date, watched_with)
    values (v_user, p_movie_id, p_bucket, v_pos, 0,
            coalesce(p_watch_date, v_old.watch_date),
            coalesce(v_old.watched_with, '{}'))
    returning * into v_row;

    perform rescore_bucket(v_user, p_bucket, v_kind);

    delete from watchlist where user_id = v_user and movie_id = p_movie_id;

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

        insert into notifications (recipient_id, actor_id, kind, movie_id)
        select w.user_id, v_user, 'friend_ranked_watchlist_movie', p_movie_id
        from watchlist w
        join follows f on f.follower_id = w.user_id and f.following_id = v_user
        where w.movie_id = p_movie_id;
    end if;

    select * into v_row from rankings where id = v_row.id;
    return v_row;
end $$;

-- 4) rank_remove: scope the gap-close + rescore by media kind.
create or replace function public.rank_remove(p_movie_id integer) returns void
language plpgsql security definer set search_path = public as $$
declare
    v_user uuid := auth.uid();
    v_kind text;
    v_old rankings%rowtype;
begin
    if v_user is null then raise exception 'not authenticated'; end if;
    perform pg_advisory_xact_lock(hashtext(v_user::text || ':rankings'));

    select * into v_old from rankings where user_id = v_user and movie_id = p_movie_id;
    if not found then return; end if;

    select media_kind into v_kind from movies where tmdb_id = p_movie_id;
    v_kind := coalesce(v_kind, 'movie');

    delete from rankings where id = v_old.id;
    update rankings r set position = r.position - 1
    from movies m
    where m.tmdb_id = r.movie_id and r.user_id = v_user
      and r.bucket = v_old.bucket and m.media_kind = v_kind
      and r.position > v_old.position;
    perform rescore_bucket(v_user, v_old.bucket, v_kind);
end $$;

-- 5) Rescore every existing (user, bucket, media_kind) group with the new math.
do $$
declare g record;
begin
    for g in
        select distinct r.user_id, r.bucket, m.media_kind
        from rankings r join movies m on m.tmdb_id = r.movie_id
    loop
        perform rescore_bucket(g.user_id, g.bucket, g.media_kind);
    end loop;
end $$;
