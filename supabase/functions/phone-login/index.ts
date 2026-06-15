// phone-login: sign in with phone + password (no OTP). The phone→account
// lookup happens server-side with the service role, so phone→email is never
// exposed to clients (no enumeration of who's registered) and we don't need
// Supabase's phone-auth provider or any SMS. Returns a session the client
// then adopts. Called pre-auth, so verify_jwt is disabled.

import { createClient } from "jsr:@supabase/supabase-js@2";

const URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const ANON = Deno.env.get("SUPABASE_ANON_KEY")!;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  try {
    const { phone, password } = await req.json();
    const key = String(phone ?? "").replace(/\D/g, "").slice(-10);
    if (key.length < 10 || typeof password !== "string" || password.length === 0) {
      return json({ error: "invalid_credentials" }, 401);
    }

    const admin = createClient(URL, SERVICE);
    const { data: row } = await admin
      .from("user_phones")
      .select("user_id")
      .eq("phone_key", key)
      .maybeSingle();
    // Generic response whether or not the number is registered — don't leak
    // which phone numbers have accounts.
    if (!row) return json({ error: "invalid_credentials" }, 401);

    const { data: u } = await admin.auth.admin.getUserById(row.user_id);
    const email = u?.user?.email;
    if (!email) return json({ error: "invalid_credentials" }, 401);

    const anon = createClient(URL, ANON);
    const { data: sess, error } = await anon.auth.signInWithPassword({ email, password });
    if (error || !sess?.session) return json({ error: "invalid_credentials" }, 401);

    return json({
      access_token: sess.session.access_token,
      refresh_token: sess.session.refresh_token,
    });
  } catch (_e) {
    return json({ error: "server_error" }, 500);
  }
});
