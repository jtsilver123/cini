// send-push: fan a notifications row out to the recipient's iPhones.
// Invoked by the trg_notifications_push trigger via pg_net (no JWT — the
// payload is just a notification id, and everything sent is re-read from
// the database, so a forged call can at worst re-deliver a real
// notification to its rightful owner).
//
// Required function secrets (Settings → Edge Functions):
//   APNS_KEY_P8   — APNs auth key, full PEM text
//   APNS_KEY_ID   — 10-char key id
//   APNS_TEAM_ID  — Apple team id (VRPVPJAN9G)
// Optional: APNS_TOPIC (default app.cini.ios), APNS_SANDBOX=1 to use the
// development APNs host.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const TOPIC = Deno.env.get("APNS_TOPIC") ?? "app.cini.ios";
const HOST = Deno.env.get("APNS_SANDBOX")
  ? "https://api.sandbox.push.apple.com"
  : "https://api.push.apple.com";

// ---- APNs provider token (ES256 JWT, cached ~40 min) ----
let cached: { jwt: string; at: number } | null = null;

function b64url(data: Uint8Array | string): string {
  const bytes = typeof data === "string" ? new TextEncoder().encode(data) : data;
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/, "");
}

async function apnsCreds(): Promise<{ pem: string; keyID: string; teamID: string }> {
  let pem = Deno.env.get("APNS_KEY_P8");
  let keyID = Deno.env.get("APNS_KEY_ID");
  let teamID = Deno.env.get("APNS_TEAM_ID");
  if (!pem || !keyID || !teamID) {
    // Fall back to Vault (service-role-only accessor).
    const { data } = await supabase.rpc("get_apns_secrets");
    for (const row of data ?? []) {
      if (row.name === "APNS_KEY_P8") pem ??= row.secret;
      if (row.name === "APNS_KEY_ID") keyID ??= row.secret;
      if (row.name === "APNS_TEAM_ID") teamID ??= row.secret;
    }
  }
  if (!pem || !keyID || !teamID) throw new Error("APNS secrets not configured");
  return { pem, keyID, teamID };
}

async function apnsJWT(): Promise<string> {
  if (cached && Date.now() - cached.at < 40 * 60 * 1000) return cached.jwt;
  const { pem, keyID, teamID } = await apnsCreds();

  const der = Uint8Array.from(
    atob(pem.replace(/-----[^-]+-----/g, "").replace(/\s/g, "")),
    (c) => c.charCodeAt(0),
  );
  const key = await crypto.subtle.importKey(
    "pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"],
  );
  const header = b64url(JSON.stringify({ alg: "ES256", kid: keyID }));
  const claims = b64url(JSON.stringify({ iss: teamID, iat: Math.floor(Date.now() / 1000) }));
  const sig = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" }, key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const jwt = `${header}.${claims}.${b64url(new Uint8Array(sig))}`;
  cached = { jwt, at: Date.now() };
  return jwt;
}

// ---- Notification copy (mirrors NotificationsView.headline) ----
// `actor` is the @handle; `name` is the joiner's profile name (or the handle
// if they have none) — used where a real name reads better.
function headline(kind: string, actor: string, name: string, movie: string | null): string {
  switch (kind) {
    case "new_follower": return `@${actor} started following you`;
    case "like": return `@${actor} liked your activity on ${movie ?? "a movie"}`;
    case "comment": return `@${actor} commented on ${movie ?? "a movie"}`;
    case "friend_ranked_watchlist_movie":
      return `@${actor} ranked ${movie ?? "a movie"} — it's on your Want to Watch list`;
    case "watchlist_showing":
      return `${movie ?? "A movie you want to watch"} is playing in theaters near you 🎬`;
    case "direct_rec":
      return `@${actor} recommended ${movie ?? "a movie"} to you 🎬`;
    case "invite_joined":
      return `@${actor} joined Cini from your invite 🎉 You now follow each other.`;
    case "rec_request":
      return `@${actor} wants a rec from you — send one 🎬`;
    case "follow_request":
      return `@${actor} asked to follow you`;
    case "follow_request_approved":
      return `@${actor} accepted your follow request`;
    case "contact_joined":
      return `${name} from your contacts just joined Cini 🎬`;
    case "saved_your_rank":
      return `@${actor} saved ${movie ?? "a title"} — you ranked it 🔖`;
    case "streak_reminder":
      return `Your streak ends Sunday — rank one title to keep it alive 🔥`;
    case "tonight_pick":
      return `Tonight's pick: ${movie ?? "a film for you"} 🍿`;
    case "streaming_now":
      return `${movie ?? "A title you saved"} is streaming now 🍿`;
    case "season_premiere":
      return `New season incoming — ${movie ?? "a show you ranked"} returns this week 🎬`;
    case "rate_nudge":
      return `Seen ${movie ?? "that movie you saved"} yet? Tap to rank it ⭐️`;
    case "friend_loved":
      return `@${actor} just rated ${movie ?? "a movie"} — one of your favorites 🍿`;
    default: return `@${actor} did something new on Cini`;
  }
}

Deno.serve(async (req: Request) => {
  try {
    const { notification_id } = await req.json();
    if (typeof notification_id !== "string") {
      return new Response("bad request", { status: 400 });
    }

    const { data: n } = await supabase
      .from("notifications")
      .select("id, recipient_id, kind, movie_id, actor_id, actor:profiles!notifications_actor_id_fkey(username, display_name), movies(title)")
      .eq("id", notification_id)
      .maybeSingle();
    if (!n) return new Response("unknown notification", { status: 404 });

    const { data: tokens } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", n.recipient_id);
    if (!tokens?.length) return new Response("no devices", { status: 200 });

    const { count } = await supabase
      .from("notifications")
      .select("id", { count: "exact", head: true })
      .eq("recipient_id", n.recipient_id)
      .is("read_at", null);

    // kind/movie_id/actor_* ride along so tapping the push deep-links:
    // movie pushes open the movie page, follower pushes the profile.
    const uname = (n.actor as any)?.username ?? "someone";
    const dname = (n.actor as any)?.display_name;
    const name = (dname && dname.length) ? dname : `@${uname}`;
    const body = {
      aps: {
        alert: {
          title: "Cini",
          body: headline(n.kind, uname, name, (n.movies as any)?.title ?? null),
        },
        badge: count ?? 1,
        sound: "default",
      },
      kind: n.kind,
      movie_id: n.movie_id,
      actor_id: n.actor_id,
      actor_username: (n.actor as any)?.username ?? null,
    };

    const jwt = await apnsJWT();
    const results = await Promise.allSettled(tokens.map(async ({ token }) => {
      const res = await fetch(`${HOST}/3/device/${token}`, {
        method: "POST",
        headers: {
          "authorization": `bearer ${jwt}`,
          "apns-topic": TOPIC,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: JSON.stringify(body),
      });
      if (res.status === 410 || (res.status === 400 && (await res.text()).includes("BadDeviceToken"))) {
        await supabase.from("device_tokens").delete().eq("token", token);
      }
      return res.status;
    }));

    return new Response(JSON.stringify({ sent: results.map((r) => r.status === "fulfilled" ? r.value : String(r.reason)) }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    // Missing APNS secrets land here — log and succeed so pg_net retries
    // don't pile up. In-app notifications are unaffected.
    console.error("send-push:", e);
    return new Response("skipped", { status: 200 });
  }
});
