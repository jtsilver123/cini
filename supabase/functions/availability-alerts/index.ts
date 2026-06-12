// availability-alerts: daily cron. Two checks, both TMDB-frugal (one
// request per DISTINCT title per run):
//  1. streaming_now — a Want-to-Watch title with an active streaming
//     alert just became streamable in the US.
//  2. season_premiere — a show the user RANKED has a new season
//     premiering within the next week (once per user+show+season).
// Delivery rides notifications -> trigger -> send-push, like everything.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

function tmdbPath(id: number, suffix = ""): string {
  return id < 0 ? `/tv/${-id}${suffix}` : `/movie/${id}${suffix}`;
}

Deno.serve(async (_req: Request) => {
  try {
    const { data: secrets } = await supabase.rpc("get_apns_secrets");
    const key = (secrets ?? []).find((s: any) => s.name === "TMDB_API_KEY")?.secret;
    if (!key) return new Response("no tmdb key", { status: 200 });

    let streamingNotified = 0;
    let seasonNotified = 0;

    // ---- 1. Streaming alerts ----
    const { data: alerts } = await supabase
      .from("streaming_alerts")
      .select("user_id, movie_id")
      .is("notified_at", null);
    const byMovie = new Map<number, string[]>();
    for (const a of alerts ?? []) {
      if (!byMovie.has(a.movie_id)) byMovie.set(a.movie_id, []);
      byMovie.get(a.movie_id)!.push(a.user_id);
    }
    for (const [movieID, users] of byMovie) {
      const res = await fetch(
        `https://api.themoviedb.org/3${tmdbPath(movieID, "/watch/providers")}?api_key=${key}`,
      );
      if (!res.ok) continue;
      const providers = await res.json();
      const flatrate = providers?.results?.US?.flatrate ?? [];
      if (!flatrate.length) continue;
      for (const userID of users) {
        const { error } = await supabase
          .from("streaming_alerts")
          .update({ notified_at: new Date().toISOString() })
          .eq("user_id", userID).eq("movie_id", movieID)
          .is("notified_at", null);
        if (error) continue;
        await supabase.from("notifications").insert({
          recipient_id: userID,
          kind: "streaming_now",
          movie_id: movieID,
        });
        streamingNotified++;
      }
    }

    // ---- 2. Season premieres for ranked shows ----
    const { data: tvRankings } = await supabase
      .from("rankings")
      .select("user_id, movie_id")
      .lt("movie_id", 0);
    const byShow = new Map<number, string[]>();
    for (const r of tvRankings ?? []) {
      if (!byShow.has(r.movie_id)) byShow.set(r.movie_id, []);
      byShow.get(r.movie_id)!.push(r.user_id);
    }
    const soon = new Date();
    soon.setDate(soon.getDate() + 7);
    for (const [showID, users] of byShow) {
      const res = await fetch(
        `https://api.themoviedb.org/3/tv/${-showID}?api_key=${key}`,
      );
      if (!res.ok) continue;
      const show = await res.json();
      const next = show?.next_episode_to_air;
      // Only season PREMIERES — episode drops would be noise.
      if (!next || next.episode_number !== 1 || !next.air_date) continue;
      const airDate = new Date(next.air_date);
      if (airDate > soon) continue;
      for (const userID of users) {
        // Record first so a crash can't double-notify.
        const { error } = await supabase.from("season_notices").insert({
          user_id: userID,
          movie_id: showID,
          season: next.season_number,
        });
        if (error) continue; // duplicate = already notified
        await supabase.from("notifications").insert({
          recipient_id: userID,
          kind: "season_premiere",
          movie_id: showID,
        });
        seasonNotified++;
      }
    }

    return new Response(JSON.stringify({ streamingNotified, seasonNotified }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("availability-alerts:", e);
    return new Response("skipped", { status: 200 });
  }
});
