-- 0100_admin_dashboard.sql
-- Backend for the admin dashboard (admin.trycini.com / trycini.com/admin). All
-- functions are SECURITY DEFINER so they can aggregate across every user's rows
-- despite RLS, but each one hard-gates on is_admin() — only the founder's account
-- can read them. The public anon key in the dashboard page can call them, but a
-- non-admin gets a 'forbidden' error. No service-role key ever leaves the server.

create or replace function public.is_admin()
returns boolean language sql stable security definer set search_path = public as $$
  select auth.uid() = 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid;
$$;
revoke all on function public.is_admin() from public, anon;
grant execute on function public.is_admin() to authenticated;

-- Headline KPIs as one JSON object.
create or replace function public.admin_overview()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select jsonb_build_object(
    'total_users',     (select count(*) from profiles),
    'new_users_7d',    (select count(*) from profiles where coalesce(member_since, created_at) > now() - interval '7 days'),
    'new_users_30d',   (select count(*) from profiles where coalesce(member_since, created_at) > now() - interval '30 days'),
    'active_7d',       (select count(distinct user_id) from feed_events where created_at > now() - interval '7 days'),
    'total_rankings',  (select count(*) from rankings),
    'movies_ranked',   (select count(*) from rankings where movie_id > 0),
    'tv_ranked',       (select count(*) from rankings where movie_id < 0),
    'rankings_7d',     (select count(*) from rankings where created_at > now() - interval '7 days'),
    'avg_score',       (select round(avg(score), 2) from rankings),
    'loved',           (select count(*) from rankings where bucket = 'loved'),
    'fine',            (select count(*) from rankings where bucket = 'fine'),
    'disliked',        (select count(*) from rankings where bucket = 'disliked'),
    'total_bookmarks', (select count(*) from watchlist),
    'bookmarks_7d',    (select count(*) from watchlist where created_at > now() - interval '7 days'),
    'total_passes',    (select count(*) from rec_passes),
    'passes_7d',       (select count(*) from rec_passes where created_at > now() - interval '7 days'),
    'total_follows',   (select count(*) from follows),
    'total_invites',   (select count(*) from referrals),
    'invites_7d',      (select count(*) from referrals where created_at > now() - interval '7 days'),
    'catalog_titles',  (select count(*) from movies),
    'generated_at',    now()
  ) into result;
  return result;
end $$;
revoke all on function public.admin_overview() from public, anon;
grant execute on function public.admin_overview() to authenticated;

-- Daily time series for the trend charts (signups, rankings, bookmarks, passes).
create or replace function public.admin_trends(p_days int default 30)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  with days as (
    select generate_series(current_date - (p_days - 1), current_date, interval '1 day')::date as d
  )
  select jsonb_agg(jsonb_build_object(
           'date',      to_char(days.d, 'YYYY-MM-DD'),
           'signups',   (select count(*) from profiles p where coalesce(p.member_since, p.created_at)::date = days.d),
           'rankings',  (select count(*) from rankings r where r.created_at::date = days.d),
           'bookmarks', (select count(*) from watchlist w where w.created_at::date = days.d),
           'passes',    (select count(*) from rec_passes rp where rp.created_at::date = days.d)
         ) order by days.d)
  into result from days;
  return coalesce(result, '[]'::jsonb);
end $$;
revoke all on function public.admin_trends(int) from public, anon;
grant execute on function public.admin_trends(int) to authenticated;

-- Most-ranked titles (movies + shows), for an at-a-glance "what's hot" list.
create or replace function public.admin_top_titles(p_limit int default 10)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select coalesce(jsonb_agg(j order by cnt desc), '[]'::jsonb) into result from (
    select jsonb_build_object('title', m.title, 'count', count(*),
                              'tv', (r.movie_id < 0), 'avg', round(avg(r.score), 1)) as j,
           count(*) as cnt
    from rankings r join movies m on m.tmdb_id = r.movie_id
    group by m.title, (r.movie_id < 0)
    order by count(*) desc
    limit p_limit
  ) s;
  return result;
end $$;
revoke all on function public.admin_top_titles(int) from public, anon;
grant execute on function public.admin_top_titles(int) to authenticated;

-- Recent activity stream across all users.
create or replace function public.admin_recent_activity(p_limit int default 40)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare result jsonb;
begin
  if not is_admin() then raise exception 'forbidden'; end if;
  select coalesce(jsonb_agg(j order by c desc), '[]'::jsonb) into result from (
    select jsonb_build_object('kind', fe.event_type, 'user', p.username,
                              'title', m.title, 'at', fe.created_at) as j,
           fe.created_at as c
    from feed_events fe
    left join profiles p on p.id = fe.user_id
    left join movies m on m.tmdb_id = fe.movie_id
    order by fe.created_at desc
    limit p_limit
  ) s;
  return result;
end $$;
revoke all on function public.admin_recent_activity(int) from public, anon;
grant execute on function public.admin_recent_activity(int) to authenticated;
