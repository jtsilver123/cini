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
    case "new_follower": return `${name} started following you`;
    case "like": return `@${actor} liked your post about ${movie ?? "a movie"}`;
    case "comment": return `@${actor} commented on ${movie ?? "a movie"}`;
    case "friend_ranked_watchlist_movie":
      return `@${actor} ranked ${movie ?? "a movie"} — it's on your Want to Watch list`;
    case "watchlist_showing":
      return `🎟️ Tickets are on sale near you for ${movie ?? "a movie on your Want to Watch"} — good seats go fast`;
    case "direct_rec":
      return `@${actor} recommended ${movie ?? "a movie"} to you 🎬`;
    case "invite_joined":
      return `${name} joined Cini from your invite 🎉 You now follow each other.`;
    case "rec_request":
      return `@${actor} wants a rec from you — send one 🎬`;
    case "follow_request":
      return `@${actor} asked to follow you`;
    case "follow_request_approved":
      return `@${actor} accepted your follow request`;
    case "contact_joined":
      return `${name} from your contacts just joined Cini 🎬`;
    case "saved_your_rank":
      return `@${actor} added ${movie ?? "a title"} to their Want to Watch — you ranked it 🔖`;
    case "streak_reminder":
      return `Your streak ends Sunday — rank one title to keep it alive 🔥`;
    case "tonight_pick":
      return `Tonight's pick: ${movie ?? "a film for you"} 🍿`;
    case "watch_match":
      return `You and @${actor} both want to watch ${movie ?? "the same movie"} — plan a movie night? 🍿`;
    case "watch_invite":
      return `@${actor} wants to watch ${movie ?? "a movie"} together — when works? 🎬`;
    case "watch_accept":
      return `@${actor} is in for ${movie ?? "movie night"} 🍿 It's a plan`;
    case "streaming_now":
      return `${movie ?? "A title you saved"} is streaming now — it's on your Want to Watch 🍿`;
    case "season_premiere":
      return `New season of ${movie ?? "a show you ranked"} premieres this week 🎬`;
    case "rate_nudge":
      return `Seen ${movie ?? "that movie you saved"} yet? Tap to rank it 🎬`;
    case "friend_loved":
      return `@${actor} just ranked ${movie ?? "a movie"} — one of your favorites 🍿`;
    case "friend_watching":
      return `@${actor} started watching ${movie ?? "a show"} — you're watching it too 📺`;
    case "caught_up":
      return `@${actor} is all caught up on ${movie ?? "a show you're watching"} 🎉`;
    case "mention":
      return `@${actor} mentioned you in a comment on ${movie ?? "a movie"} 💬`;
    case "rec_passed":
      return `@${actor} passed on your rec${movie ? ` of ${movie}` : ""}`;
    case "rec_watched":
      return `@${actor} watched ${movie ?? "a movie"} you recommended 🎬`;
    default: return `New from @${actor} on Cini — tap to take a look`;
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
      .select("id, recipient_id, kind, movie_id, actor_id, event_id, message, actor:profiles!notifications_actor_id_fkey(username, display_name), movies(title)")
      .eq("id", notification_id)
      .maybeSingle();
    if (!n) return new Response("unknown notification", { status: 404 });

    const { data: tokens } = await supabase
      .from("device_tokens")
      .select("token")
      .eq("user_id", n.recipient_id);
    if (!tokens?.length) {
      console.log(`send-push ${notification_id} kind=${n.kind} recipient=${n.recipient_id}: no devices`);
      return new Response("no devices", { status: 200 });
    }
    console.log(`send-push ${notification_id} kind=${n.kind} recipient=${n.recipient_id} tokens=${tokens.length}`);

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
    // Append a free-text message (e.g. why they passed on a rec) to the body.
    let alertBody = headline(n.kind, uname, name, (n.movies as any)?.title ?? null);
    if (n.kind === "watchlist_showing" && (n as any).message) {
      // The ticket alert embeds WHEN — these sell out, so the date is the
      // point: "…— first showing Fri, Jul 24. Tickets go fast".
      const when = String((n as any).message).replace(/^First showing /, "first showing ");
      alertBody = `🎟️ ${(n.movies as any)?.title ?? "A movie on your Want to Watch"} is in theaters near you — ${when}. Tickets go fast`;
    } else if ((n as any).message) alertBody += `: “${(n as any).message}”`;
    const body = {
      aps: {
        alert: {
          title: "Cini",
          body: alertBody,
        },
        badge: count ?? 1,
        sound: "default",
      },
      kind: n.kind,
      movie_id: n.movie_id,
      actor_id: n.actor_id,
      actor_username: (n.actor as any)?.username ?? null,
      // Comment/mention pushes ride the feed event id so a tap lands on the
      // actual comment thread, not just the movie page.
      event_id: (n as any).event_id ?? null,
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
      // Log every non-200 with APNs's reason so delivery failures aren't silent
      // (this is how a "push didn't arrive" bug becomes diagnosable).
      if (res.status !== 200) {
        const text = await res.text();
        console.error(`send-push ${notification_id} APNs ${res.status} token=${token.slice(0, 8)}…: ${text}`);
        if (res.status === 410 || (res.status === 400 && text.includes("BadDeviceToken"))) {
          await supabase.from("device_tokens").delete().eq("token", token);
        }
      }
      return res.status;
    }));

    const statuses = results.map((r) => r.status === "fulfilled" ? r.value : String(r.reason));
    console.log(`send-push ${notification_id} kind=${n.kind} delivered=${JSON.stringify(statuses)}`);
    return new Response(JSON.stringify({ sent: statuses }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    // Missing APNS secrets land here — log and succeed so pg_net retries
    // don't pile up. In-app notifications are unaffected.
    console.error("send-push:", e);
    return new Response("skipped", { status: 200 });
  }
});
