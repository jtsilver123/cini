-- "Everyone gets Jake as a friend" — Beli seeds every new user with a default
-- friend (their "Judy"). Cini auto-follows the founder (@jtsilver123) so a new
-- account's feed, Friend Scores, and leaderboard aren't empty on day one.

-- The founder is followed by everyone, so a "new_follower" notification for
-- them is pure noise (and a push per signup). Skip notifying when the account
-- being followed is the founder.
create or replace function public.notify_on_follow()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    if new.following_id <> 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid then
        insert into notifications (recipient_id, actor_id, kind)
        values (new.following_id, new.follower_id, 'new_follower');
    end if;
    return new;
end $function$;

-- Auto-follow the founder whenever a profile is created.
create or replace function public.follow_founder_on_signup()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
    if new.id <> 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid then
        insert into follows (follower_id, following_id)
        values (new.id, 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid)
        on conflict (follower_id, following_id) do nothing;
    end if;
    return new;
end $function$;

drop trigger if exists trg_follow_founder on profiles;
create trigger trg_follow_founder
    after insert on profiles
    for each row execute function public.follow_founder_on_signup();

-- Backfill: everyone who already has an account now follows the founder too.
insert into follows (follower_id, following_id)
select p.id, 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid
from profiles p
where p.id <> 'c8a4e18e-7b5b-405d-bb74-6e1e79702f60'::uuid
on conflict (follower_id, following_id) do nothing;
