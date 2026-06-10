-- Row Level Security for Cini.
-- Visibility model:
--   * Public accounts: rankings, watchlists, public notes, performances,
--     labels, and feed events are readable by any authenticated user.
--   * Private accounts (profiles.is_private): the same data is readable only
--     by accepted followers (rows in follows) and the owner.
--   * Private notes (notes.is_private) are readable ONLY by their owner,
--     regardless of account privacy.
--   * All writes are owner-only.

alter table public.profiles              enable row level security;
alter table public.movies                enable row level security;
alter table public.rankings              enable row level security;
alter table public.watchlist             enable row level security;
alter table public.notes                 enable row level security;
alter table public.favorite_performances enable row level security;
alter table public.labels                enable row level security;
alter table public.ranking_labels        enable row level security;
alter table public.follows               enable row level security;
alter table public.feed_events           enable row level security;
alter table public.likes                 enable row level security;
alter table public.comments              enable row level security;
alter table public.notifications         enable row level security;
alter table public.taste_matches         enable row level security;
alter table public.invites               enable row level security;

-- Can the current user see `owner`'s content? (owner themselves, public
-- account, or follower of a private account)
create or replace function public.can_view(owner uuid) returns boolean
language sql stable security definer set search_path = public as $$
    select owner = auth.uid()
        or exists (select 1 from profiles p where p.id = owner and not p.is_private)
        or exists (select 1 from follows f
                   where f.following_id = owner and f.follower_id = auth.uid());
$$;

-- Profiles: directory is public (usernames/avatars are discoverable).
create policy profiles_select on public.profiles
    for select to authenticated using (true);
create policy profiles_insert on public.profiles
    for insert to authenticated with check (id = auth.uid());
create policy profiles_update on public.profiles
    for update to authenticated using (id = auth.uid());

-- Movies: shared metadata cache, readable by all; inserts go through the
-- cache_movie RPC (security definer) so clients can't corrupt rows freely.
create policy movies_select on public.movies
    for select to authenticated using (true);

-- Rankings
create policy rankings_select on public.rankings
    for select to authenticated using (public.can_view(user_id));
create policy rankings_write on public.rankings
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Watchlist
create policy watchlist_select on public.watchlist
    for select to authenticated using (public.can_view(user_id));
create policy watchlist_write on public.watchlist
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Notes: private notes never leave their owner.
create policy notes_select on public.notes
    for select to authenticated
    using (user_id = auth.uid() or (not is_private and public.can_view(user_id)));
create policy notes_write on public.notes
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Favorite performances
create policy fav_perf_select on public.favorite_performances
    for select to authenticated using (public.can_view(user_id));
create policy fav_perf_write on public.favorite_performances
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Labels: built-ins (owner_id null) visible to all; user labels follow can_view.
create policy labels_select on public.labels
    for select to authenticated using (owner_id is null or public.can_view(owner_id));
create policy labels_write on public.labels
    for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());

create policy ranking_labels_select on public.ranking_labels
    for select to authenticated
    using (exists (select 1 from rankings r
                   where r.id = ranking_id and public.can_view(r.user_id)));
create policy ranking_labels_write on public.ranking_labels
    for all to authenticated
    using (exists (select 1 from rankings r
                   where r.id = ranking_id and r.user_id = auth.uid()))
    with check (exists (select 1 from rankings r
                        where r.id = ranking_id and r.user_id = auth.uid()));

-- Follows: edges visible to either endpoint and to anyone who can view the
-- followed account; you can only create/delete your own outgoing edges.
create policy follows_select on public.follows
    for select to authenticated
    using (follower_id = auth.uid() or public.can_view(following_id));
create policy follows_insert on public.follows
    for insert to authenticated with check (follower_id = auth.uid());
create policy follows_delete on public.follows
    for delete to authenticated using (follower_id = auth.uid());

-- Feed events
create policy feed_events_select on public.feed_events
    for select to authenticated using (public.can_view(user_id));
create policy feed_events_write on public.feed_events
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Likes & comments: visible wherever the underlying event is visible.
create policy likes_select on public.likes
    for select to authenticated
    using (exists (select 1 from feed_events e
                   where e.id = event_id and public.can_view(e.user_id)));
create policy likes_write on public.likes
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

create policy comments_select on public.comments
    for select to authenticated
    using (exists (select 1 from feed_events e
                   where e.id = event_id and public.can_view(e.user_id)));
create policy comments_write on public.comments
    for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- Notifications: recipient-only.
create policy notifications_select on public.notifications
    for select to authenticated using (recipient_id = auth.uid());
create policy notifications_update on public.notifications
    for update to authenticated using (recipient_id = auth.uid());

-- Taste matches: visible to either endpoint; written by the nightly job
-- (service role bypasses RLS).
create policy taste_matches_select on public.taste_matches
    for select to authenticated using (user_a = auth.uid() or user_b = auth.uid());

-- Invites: inviter sees their codes; redemption handled by RPC.
create policy invites_select on public.invites
    for select to authenticated using (inviter_id = auth.uid());
create policy invites_insert on public.invites
    for insert to authenticated with check (inviter_id = auth.uid());
