-- Labels save + aggregate (mirrors prod migration
-- `label_persistence_and_aggregation`).

create or replace function public.set_ranking_labels(p_movie_id integer, p_labels text[])
returns void
language plpgsql security definer set search_path = public as $$
declare
  v_ranking uuid;
  v_label text;
  v_label_id uuid;
begin
  if auth.uid() is null then
    raise exception 'not authenticated';
  end if;
  select id into v_ranking from rankings
    where user_id = auth.uid() and movie_id = p_movie_id;
  if v_ranking is null then
    return;
  end if;

  delete from ranking_labels where ranking_id = v_ranking;

  foreach v_label in array p_labels loop
    v_label := trim(v_label);
    if v_label = '' or char_length(v_label) > 40 then continue; end if;
    select id into v_label_id from labels
      where owner_id = auth.uid() and lower(name) = lower(v_label);
    if v_label_id is null then
      insert into labels (owner_id, name) values (auth.uid(), v_label)
        returning id into v_label_id;
    end if;
    insert into ranking_labels (ranking_id, label_id)
      values (v_ranking, v_label_id)
      on conflict do nothing;
  end loop;
end $$;

revoke all on function public.set_ranking_labels(integer, text[]) from public, anon;
grant execute on function public.set_ranking_labels(integer, text[]) to authenticated;

create or replace function public.movie_top_labels(p_movie_id integer)
returns table (name text, n bigint)
language sql stable security definer set search_path = public as $$
  select initcap(min(l.name)) as name, count(*) as n
  from ranking_labels rl
  join labels l on l.id = rl.label_id
  join rankings r on r.id = rl.ranking_id
  where r.movie_id = p_movie_id
  group by lower(l.name)
  order by n desc, name
  limit 6;
$$;

revoke all on function public.movie_top_labels(integer) from public, anon;
grant execute on function public.movie_top_labels(integer) to authenticated;
