// send-import-link: one tap in the app emails the signed-in user their
// private desktop-import link — no mail composer, no typing your own
// address. Sender is the verified hello@trycini.com via Resend; the API
// key lives in Vault behind the service-role-only secrets accessor.

import { createClient } from "jsr:@supabase/supabase-js@2";

const service = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return json(405, { error: "POST only" });
  try {
    // Caller identity from the forwarded JWT (verify_jwt gated us already).
    const authed = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_ANON_KEY")!,
      { global: { headers: { Authorization: req.headers.get("Authorization") ?? "" } } },
    );
    const { data: { user } } = await authed.auth.getUser();
    if (!user) return json(401, { error: "unauthorized" });
    if (!user.email) return json(400, { error: "no_email" });

    const { code, name } = await req.json().catch(() => ({}));
    if (typeof code !== "string" || !/^[A-Z2-9]{6}$/.test(code)) {
      return json(400, { error: "bad_code" });
    }
    // The code must be the caller's own — this sender mails import links to
    // their owner, nothing else to no one else.
    const { data: pending } = await service.from("pending_imports")
      .select("user_id").eq("code", code).maybeSingle();
    if (!pending || pending.user_id !== user.id) {
      return json(403, { error: "not_your_code" });
    }

    const { data: secrets } = await service.rpc("get_apns_secrets");
    const key = (secrets ?? []).find(
      (row: { name: string }) => row.name === "RESEND_API_KEY",
    )?.secret;
    if (!key) return json(500, { error: "not_configured" });

    let link = `https://trycini.com/import/?code=${code}`;
    const first = typeof name === "string" ? name.trim().slice(0, 30) : "";
    if (first) link += `&name=${encodeURIComponent(first)}`;

    // color-scheme lets dark-mode mail clients pick readable text instead
    // of rendering a hard-coded near-black on near-black.
    const html = `
      <div style="font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:15px;line-height:1.5;color-scheme:light dark;">
        <p>Open this link <b>on your computer</b> to bring your history into Cini:</p>
        <p><a href="${link}" style="font-weight:700;">${link}</a></p>
        <ol>
          <li>Open the link on your computer.</li>
          <li>Grab your export from <b>Letterboxd</b>, <b>IMDb</b>, or <b>Netflix</b> (a .zip or a .csv both work) and drop it in.</li>
          <li>Your movies and shows beam straight to Cini on your phone.</li>
        </ol>
        <p style="font-size:13px;opacity:0.65;"><i>This link works for 30 minutes — grab a fresh one in the app if it expires.</i></p>
      </div>`;

    const res = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        from: "Cini <hello@trycini.com>",
        to: [user.email],
        subject: "Your Cini import link",
        html,
      }),
    });
    if (!res.ok) {
      console.error("resend:", res.status, await res.text());
      return json(502, { error: "send_failed" });
    }
    return json(200, { ok: true, to: user.email });
  } catch (e) {
    console.error("send-import-link:", e);
    return json(500, { error: "unexpected" });
  }
});
