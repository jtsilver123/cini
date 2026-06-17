-- Likes on individual comments (Beli-style). A comment-like is visible
-- wherever the underlying comment is (its event author is viewable); you can
-- only like as yourself.
create table public.comment_likes (
    user_id    uuid not null references public.profiles (id) on delete cascade,
    comment_id uuid not null references public.comments (id) on delete cascade,
    created_at timestamptz not null default now(),
    primary key (user_id, comment_id)
);

alter table public.comment_likes enable row level security;

create policy comment_likes_select on public.comment_likes
    for select to authenticated
    using (exists (
        select 1 from public.comments c
        join public.feed_events e on e.id = c.event_id
        where c.id = comment_id and public.can_view(e.user_id)));

create policy comment_likes_write on public.comment_likes
    for all to authenticated
    using (user_id = auth.uid())
    with check (user_id = auth.uid());

create index comment_likes_comment_idx on public.comment_likes (comment_id);
