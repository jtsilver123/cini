-- 0098_continue_watching_picks.sql
-- Tonight's Picks now lead with shows you're mid-binge on. This returns the
-- signed-in user's in-progress shows (newest activity first), skipping anything
-- they're caught up on — a caught-up show has no next episode to watch tonight,
-- so it shouldn't headline the daily pick. The app turns each into a "Continue
-- watching · S2 · E5" card ahead of the Want to Watch picks.
create or replace function public.continue_watching_picks(p_limit integer default 10)
returns table(show_id integer, season integer, episode integer, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.show_id, sp.season, sp.episode, sp.updated_at
  from show_progress sp
  where sp.user_id = auth.uid()
    and sp.caught_up = false
  order by sp.updated_at desc
  limit p_limit;
$$;
revoke all on function public.continue_watching_picks(integer) from public, anon;
grant execute on function public.continue_watching_picks(integer) to authenticated;
