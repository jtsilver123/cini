-- Recreating functions resets grants: movie_friend_scores picked up
-- anon execute in migration 0024, and not_blocked was born with it.
-- Policies invoke can_view/not_blocked as the calling role, so
-- authenticated keeps EXECUTE; anon gets nothing.
revoke execute on function public.movie_friend_scores(integer) from anon;
revoke execute on function public.not_blocked(uuid) from anon;
revoke execute on function public.can_view(uuid) from anon;
