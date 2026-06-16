// tonight-pick: the evening "watch this tonight" push. Triggered hourly by a
// pg_cron job; each run sends to whichever users are currently in their local
// 7pm hour (tonight_pick_candidates() does the timezone math). For each, it
// computes their pick (tonight_pick_for), records a once-a-day dedup row, and
// inserts a notification — the existing trg_notifications_push trigger then
// fans it out to their devices via send-push.
//
// No JWT: it only reads server-side state and writes notifications the user
// would get anyway, so a forged call can at worst re-send a real pick.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

Deno.serve(async (_req: Request) => {
  try {
    const { data: candidates, error } = await supabase.rpc("tonight_pick_candidates");
    if (error) throw error;

    let sent = 0;
    for (const c of candidates ?? []) {
      const { data: pick } = await supabase.rpc("tonight_pick_for", { p_user: c.user_id });
      const row = (pick as any[] | null)?.[0];
      if (!row) continue;

      // Claim the day's slot first; a unique-key conflict means we already
      // sent today (e.g. the cron overlapping), so skip silently.
      const { error: dErr } = await supabase
        .from("tonight_pick_sends")
        .insert({ user_id: c.user_id, sent_on: c.local_date, movie_id: row.movie_id });
      if (dErr) continue;

      await supabase.from("notifications").insert({
        recipient_id: c.user_id,
        kind: "tonight_pick",
        movie_id: row.movie_id,
      });
      sent++;
    }

    return new Response(JSON.stringify({ candidates: candidates?.length ?? 0, sent }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    // Log and succeed so pg_net retries don't pile up; in-app picks are fine.
    console.error("tonight-pick:", e);
    return new Response("skipped", { status: 200 });
  }
});
