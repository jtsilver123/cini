-- Unbookmarking now behaves like deleting a rating: the activity that
-- advertised the saved title is pulled too (likes/comments/notifications
-- cascade via FK), instead of the feed forever claiming "wants to watch
-- X". Applied to prod as `watchlist_toggle_cleans_feed_event`; a backfill
-- delete of orphaned watchlisted events ran alongside (zero rows matched).
create or replace function public.watchlist_toggle(p_movie_id integer)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
    v_user uuid := auth.uid();
    v_deleted integer;
begin
    delete from watchlist where user_id = v_user and movie_id = p_movie_id;
    get diagnostics v_deleted = row_count;
    if v_deleted > 0 then
        delete from feed_events
        where user_id = v_user and movie_id = p_movie_id
          and event_type = 'watchlisted';
        return false;
    end if;

    insert into watchlist (user_id, movie_id) values (v_user, p_movie_id);
    insert into feed_events (user_id, event_type, movie_id)
    values (v_user, 'watchlisted', p_movie_id);
    return true;
end $function$;

-- create or replace resets grants to PUBLIC — re-pin them (0025 lesson).
revoke all on function public.watchlist_toggle(integer) from public, anon;
grant execute on function public.watchlist_toggle(integer) to authenticated;
