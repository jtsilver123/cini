-- One-tap import email: the send-import-link edge function mails the user
-- their private desktop-import link from hello@trycini.com via Resend.
-- The Resend key lives in Vault (added out-of-band; never in this repo) —
-- extend the service-role-only secrets accessor to hand it out.
create or replace function public.get_apns_secrets()
returns table (name text, secret text)
language sql security definer set search_path = '' as $$
  select name, decrypted_secret
  from vault.decrypted_secrets
  where name in ('APNS_KEY_P8', 'APNS_KEY_ID', 'APNS_TEAM_ID',
                 'GRACENOTE_API_KEY', 'TMDB_API_KEY', 'RESEND_API_KEY');
$$;

-- Defensive re-lock (prod already has this ACL; keep the file honest).
revoke all on function public.get_apns_secrets() from public, anon, authenticated;
grant execute on function public.get_apns_secrets() to service_role;
