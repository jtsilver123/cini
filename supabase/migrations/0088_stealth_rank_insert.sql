-- 0088: rank a title in stealth without ever publishing it.
--
-- Before this, a stealth rank was created PUBLIC by rank_insert (it emits a
-- 'ranked' feed event) and the client deleted that event a moment later. On a
-- slow network the rank was visible to friends in that gap. Make stealth a
-- parameter so the feed event (and the watchlist-add notifications) are simply
-- never written for a stealth rank — atomic, no window. For a re-rank that was
-- previously public, also pull the old 'ranked' event in the same transaction.
--
-- The signature gains p_stealth, so the old 4-arg overload is dropped first to
-- avoid an ambiguous PostgREST resolution.

drop function if exists public.rank_insert(integer, text, integer, date);

create or replace function public.rank_insert(
    p_movie_id integer,
    p_bucket text,
    p_position integer,
    p_watch_date date default null,
    p_stealth boolean default false
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

    -- Public ranks announce themselves; stealth ranks never do.
    if v_was_new and not p_stealth then
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

    -- A re-rank into stealth (or a stealth rank racing an older event) must
    -- leave nothing public behind.
    if p_stealth then
        delete from feed_events
        where user_id = v_user and movie_id = p_movie_id and event_type = 'ranked';
    end if;

    select * into v_row from rankings where id = v_row.id;
    return v_row;
end $$;

-- Re-apply the 0004 hardening to the new signature: signed-in users only.
revoke execute on function public.rank_insert(integer, text, integer, date, boolean) from public, anon;
grant execute on function public.rank_insert(integer, text, integer, date, boolean) to authenticated;
