-- Recommendation engine + shared watchlists.

-- ---------------------------------------------------------------------------
-- Personalized recs: movies your friends loved that you haven't seen,
-- weighted by taste match. score = avg(friend score × match weight).
-- ---------------------------------------------------------------------------
create or replace function public.recs_for_user(p_limit integer default 30)
returns table (movie_id integer, rec_score numeric, friend_count bigint,
               top_friend_username text)
language sql stable security definer set search_path = public as $$
    with my_movies as (
        select movie_id from rankings where user_id = auth.uid()
        union
        select movie_id from watchlist where user_id = auth.uid()
    ),
    friend_ranks as (
        select r.movie_id, r.score, p.username,
               coalesce(
                   (select tm.pct / 100.0 from taste_matches tm
                    where tm.user_a = least(auth.uid(), r.user_id)
                      and tm.user_b = greatest(auth.uid(), r.user_id)),
                   0.5) as match_weight
        from rankings r
        join follows f on f.following_id = r.user_id and f.follower_id = auth.uid()
        join profiles p on p.id = r.user_id
        where r.score >= 6.7                          -- only their loved tier
          and r.movie_id not in (select movie_id from my_movies)
    )
    select fr.movie_id,
           round(avg(fr.score * fr.match_weight) / 0.5, 1) as rec_score,
           count(*) as friend_count,
           (array_agg(fr.username order by fr.score * fr.match_weight desc))[1]
    from friend_ranks fr
    group by fr.movie_id
    order by avg(fr.score * fr.match_weight) desc, count(*) desc
    limit p_limit;
$$;

revoke execute on function public.recs_for_user(integer) from public, anon;

-- ---------------------------------------------------------------------------
-- Shared watchlists: a named list owned by a user, members can add movies.
-- ---------------------------------------------------------------------------
create table public.shared_lists (
    id         uuid primary key default gen_random_uuid(),
    owner_id   uuid not null references public.profiles (id) on delete cascade,
    name       text not null check (char_length(name) between 1 and 60),
    emoji      text not null default '🍿',
    created_at timestamptz not null default now()
);

create table public.shared_list_members (
    list_id    uuid not null references public.shared_lists (id) on delete cascade,
    user_id    uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (list_id, user_id)
);

create table public.shared_list_movies (
    list_id    uuid not null references public.shared_lists (id) on delete cascade,
    movie_id   integer not null references public.movies (tmdb_id),
    added_by   uuid not null references public.profiles (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (list_id, movie_id)
);

create index shared_list_members_user on public.shared_list_members (user_id);

alter table public.shared_lists        enable row level security;
alter table public.shared_list_members enable row level security;
alter table public.shared_list_movies  enable row level security;

create or replace function public.is_list_member(p_list uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select exists (select 1 from shared_list_members m
                   where m.list_id = p_list and m.user_id = auth.uid())
        or exists (select 1 from shared_lists l
                   where l.id = p_list and l.owner_id = auth.uid());
$$;
revoke execute on function public.is_list_member(uuid) from public, anon;

create policy shared_lists_select on public.shared_lists
    for select to authenticated using (public.is_list_member(id));
create policy shared_lists_insert on public.shared_lists
    for insert to authenticated with check (owner_id = auth.uid());
create policy shared_lists_update on public.shared_lists
    for update to authenticated using (owner_id = auth.uid());
create policy shared_lists_delete on public.shared_lists
    for delete to authenticated using (owner_id = auth.uid());

create policy slm_select on public.shared_list_members
    for select to authenticated using (public.is_list_member(list_id));
-- Owner adds members; anyone can remove themselves; owner can remove anyone.
create policy slm_insert on public.shared_list_members
    for insert to authenticated
    with check (exists (select 1 from shared_lists l
                        where l.id = list_id and l.owner_id = auth.uid())
                or user_id = auth.uid());
create policy slm_delete on public.shared_list_members
    for delete to authenticated
    using (user_id = auth.uid()
           or exists (select 1 from shared_lists l
                      where l.id = list_id and l.owner_id = auth.uid()));

create policy slmovies_select on public.shared_list_movies
    for select to authenticated using (public.is_list_member(list_id));
create policy slmovies_insert on public.shared_list_movies
    for insert to authenticated
    with check (public.is_list_member(list_id) and added_by = auth.uid());
create policy slmovies_delete on public.shared_list_movies
    for delete to authenticated
    using (added_by = auth.uid()
           or exists (select 1 from shared_lists l
                      where l.id = list_id and l.owner_id = auth.uid()));

-- Owner is implicitly a member on creation.
create or replace function public.handle_new_shared_list() returns trigger
language plpgsql security definer set search_path = public as $$
begin
    insert into shared_list_members (list_id, user_id) values (new.id, new.owner_id)
    on conflict do nothing;
    return new;
end $$;
revoke execute on function public.handle_new_shared_list() from public, anon, authenticated;

create trigger on_shared_list_created
    after insert on public.shared_lists
    for each row execute function public.handle_new_shared_list();
