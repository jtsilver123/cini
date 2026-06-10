-- Security hardening from Supabase advisor findings.

-- 1. Community scores: respect RLS (security invoker). Averages aggregate
--    only rankings the viewer is allowed to see — private accounts' data
--    stays private even in aggregate.
alter view public.movie_community_scores set (security_invoker = on);

-- 2. Pin search_path on remaining functions.
alter function public.touch_updated_at() set search_path = public;
alter function public.rescore_bucket(uuid, text) set search_path = public;

-- 3. Move pg_trgm out of public.
create schema if not exists extensions;
alter extension pg_trgm set schema extensions;

-- 4. Function execution surface.
--    Internal-only functions: no API callers at all. (Triggers don't need
--    caller EXECUTE; privileges are checked at trigger creation.)
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.touch_updated_at() from public, anon, authenticated;
revoke execute on function public.rescore_bucket(uuid, text) from public, anon, authenticated;
revoke execute on function public.refresh_taste_matches() from public, anon, authenticated;
grant execute on function public.refresh_taste_matches() to service_role;
revoke execute on function public.compute_taste_match(uuid, uuid) from public, anon, authenticated;
grant execute on function public.compute_taste_match(uuid, uuid) to service_role;

--    App RPCs: signed-in users only — never anonymous.
revoke execute on function public.cache_movie(integer, text, text, smallint, text, text, text[], text, integer, text, text) from public, anon;
revoke execute on function public.rank_insert(integer, text, integer, date) from public, anon;
revoke execute on function public.rank_remove(integer) from public, anon;
revoke execute on function public.watchlist_toggle(integer) from public, anon;
revoke execute on function public.movie_friend_scores(integer) from public, anon;
revoke execute on function public.movie_score_histogram(integer) from public, anon;
revoke execute on function public.leaderboard(text, text, text, integer) from public, anon;
revoke execute on function public.global_rank(uuid) from public, anon;
revoke execute on function public.redeem_invite(text) from public, anon;
--    can_view stays executable by authenticated: RLS policies evaluate it
--    as the querying role. anon has no policies, so revoke there.
revoke execute on function public.can_view(uuid) from public, anon;
