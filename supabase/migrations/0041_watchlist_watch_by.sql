-- Optional "watch by" goal date on a Want-to-Watch entry: set it in the
-- save popup, shown on the row, used as a gentle deadline.
alter table public.watchlist add column watch_by date;

create or replace function public.set_watch_by(p_movie_id integer, p_watch_by date)
returns void
language sql
security definer
set search_path to 'public'
as $$
    update watchlist set watch_by = p_watch_by
    where user_id = auth.uid() and movie_id = p_movie_id;
$$;
revoke all on function public.set_watch_by(integer, date) from public, anon;
grant execute on function public.set_watch_by(integer, date) to authenticated;
