-- CIN-34: "Trending" in search should reflect what Cini members are actually
-- rating and bookmarking right now, not TMDB's external buzz. Count recent
-- rankings + watchlist adds per title over a short window.
create or replace function public.trending_titles(p_days integer default 14, p_limit integer default 40)
returns table(movie_id integer, activity bigint)
language sql
stable
security definer
set search_path to 'public'
as $function$
    select movie_id, count(*) as activity
    from (
        select movie_id, created_at from rankings
        union all
        select movie_id, created_at from watchlist
    ) a
    where created_at > now() - make_interval(days => p_days)
    group by movie_id
    order by activity desc, movie_id
    limit p_limit;
$function$;

grant execute on function public.trending_titles(integer, integer) to authenticated;
