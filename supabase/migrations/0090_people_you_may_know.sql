-- People you may know: friends-of-friends discovery.
--
-- Returns accounts you do NOT already follow that are followed by people you
-- DO follow, ranked by the number of those mutual connections, then taste
-- match, then activity. This is the strongest, most honest "who should I
-- follow" signal and the lowest-friction path to a fuller feed — no cold
-- invite required. Mirrors the shape of suggested_members (so the app can
-- reuse SuggestedMember) plus a mutuals_count column.
create or replace function public.people_you_may_know(p_limit int default 12)
returns table(id uuid, username text, display_name text, avatar_url text,
              match_pct numeric, watched bigint, mutuals_count bigint)
language sql stable security definer
set search_path to 'public'
as $$
  select p.id, p.username, p.display_name, p.avatar_url,
         tm.pct as match_pct,
         (select count(*) from rankings r where r.user_id = p.id) as watched,
         count(distinct mid.follower_id) as mutuals_count
  from follows me                                       -- accounts you follow
  join follows mid on mid.follower_id = me.following_id  -- who they follow
  join profiles p on p.id = mid.following_id
  left join taste_matches tm
    on (tm.user_a = auth.uid() and tm.user_b = p.id)
    or (tm.user_b = auth.uid() and tm.user_a = p.id)
  where me.follower_id = auth.uid()
    and p.id <> auth.uid()
    and can_view(p.id)
    and not exists (
      select 1 from follows f
      where f.follower_id = auth.uid() and f.following_id = p.id
    )
  group by p.id, p.username, p.display_name, p.avatar_url, tm.pct
  order by mutuals_count desc, tm.pct desc nulls last, watched desc
  limit p_limit;
$$;

revoke execute on function public.people_you_may_know(int) from public, anon;
grant execute on function public.people_you_may_know(int) to authenticated;
