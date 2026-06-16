-- 0071_mutual_watching.sql
-- "You both are watching": shows that BOTH the viewer and the profile they're
-- looking at are currently mid-binge on (the watching twin of "you both want to
-- watch"). Gated by can_view + not blocked.
create or replace function public.mutual_watching(p_user uuid)
returns table(show_id integer, title text, poster_path text,
              season integer, episode integer, updated_at timestamptz)
language sql stable security definer set search_path = public as $$
  select sp.show_id, m.title, m.poster_path, sp.season, sp.episode, sp.updated_at
  from show_progress sp
  join show_progress other
    on other.show_id = sp.show_id and other.user_id = p_user
  join movies m on m.tmdb_id = sp.show_id
  where sp.user_id = auth.uid()
    and can_view(p_user)
    and not_blocked_pair(auth.uid(), p_user)
  order by sp.updated_at desc;
$$;
revoke all on function public.mutual_watching(uuid) from public, anon;
grant execute on function public.mutual_watching(uuid) to authenticated;
