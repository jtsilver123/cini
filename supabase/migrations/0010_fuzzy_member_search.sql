-- Typo-tolerant member search (mirrors prod migration `fuzzy_member_search`).
create index if not exists profiles_display_name_trgm
  on public.profiles using gin (display_name extensions.gin_trgm_ops);

create or replace function public.search_members(p_query text)
returns setof public.profiles
language sql stable
set search_path = public, extensions as $$
  select *
  from profiles
  where username ilike '%' || p_query || '%'
     or display_name ilike '%' || p_query || '%'
     or username % p_query
     or coalesce(display_name, '') % p_query
  order by greatest(
    similarity(username, p_query),
    similarity(coalesce(display_name, ''), p_query)
  ) desc
  limit 25;
$$;

grant execute on function public.search_members(text) to authenticated;
