// phone-login: sign in with phone OR username + password (no OTP). The
// identifier→account lookup happens server-side with the service role, so
// phone/username→email is never exposed to clients (no enumeration of who's
// registered) and we don't need Supabase's phone-auth provider or any SMS.
// Returns a session the client then adopts. Called pre-auth, so verify_jwt is
// disabled.

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
    const { phone, username, password } = await req.json();
    if (typeof password !== "string" || password.length === 0) {
      return json({ error: "invalid_credentials" }, 401);
    }

    const admin = createClient(URL, SERVICE);

    // Resolve the identifier to an account id, server-side. Username takes the
    // username path; otherwise fall back to the phone-key path.
    let userId: string | null = null;
    const uname = String(username ?? "").trim().replace(/^@+/, "");
    if (uname) {
      // Usernames are unique; ilike (no wildcards) makes the match
      // case-insensitive so "Jake" logs in the same as "jake".
      const { data: rows } = await admin
        .from("profiles")
        .select("id")
        .ilike("username", uname)
        .limit(1);
      userId = rows?.[0]?.id ?? null;
    } else {
      const key = String(phone ?? "").replace(/\D/g, "").slice(-10);
      if (key.length < 10) return json({ error: "invalid_credentials" }, 401);
      const { data: row } = await admin
        .from("user_phones")
        .select("user_id")
        .eq("phone_key", key)
        .maybeSingle();
      userId = row?.user_id ?? null;
    }
    // Generic response whether or not the identifier is registered — don't leak
    // which phones/usernames have accounts.
    if (!userId) return json({ error: "invalid_credentials" }, 401);

    const { data: u } = await admin.auth.admin.getUserById(userId);
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
