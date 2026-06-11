-- Mirrors prod migration `drop_legacy_invites`: code-based invites
-- (empty table, never called by the app) superseded by redeem_invite_from.
drop function if exists public.redeem_invite(text);
drop table if exists public.invites;
