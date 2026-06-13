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
      // Only season PREMIERES — episode drops would be noise. The date
      // must sit between yesterday (TMDB lags a little) and next week:
      // "returns this week" about a month-old premiere reads as broken.
      if (!next || next.episode_number !== 1 || !next.air_date) continue;
      const airDate = new Date(next.air_date);
      const yesterday = new Date(Date.now() - 24 * 60 * 60 * 1000);
      if (airDate < yesterday || airDate > soon) continue;
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

    // ---- 3. Rate nudges: "seen it yet? rank it" ----
    // For each pushable user, take their OLDEST unranked Want-to-Watch
    // title on the list 10+ days and not yet nudged; if it's streamable
    // in the US, nudge once. Rate-limited to one per user per ~3 days,
    // one TMDB call per user per run, one nudge per title ever.
    let rateNudged = 0;
    const { data: tokens2 } = await supabase.from("device_tokens").select("user_id");
    const pushable = [...new Set((tokens2 ?? []).map((t: any) => t.user_id))];
    const tenDaysAgo = new Date(Date.now() - 10 * 86400_000).toISOString();
    const threeDaysAgo = new Date(Date.now() - 3 * 86400_000).toISOString();

    for (const userID of pushable) {
      const { count: recent } = await supabase
        .from("rate_nudges")
        .select("movie_id", { count: "exact", head: true })
        .eq("user_id", userID)
        .gte("created_at", threeDaysAgo);
      if (recent && recent > 0) continue;   // already nudged lately

      const { data: saved } = await supabase
        .from("watchlist")
        .select("movie_id, created_at, movies(title)")
        .eq("user_id", userID)
        .lt("created_at", tenDaysAgo)
        .order("created_at", { ascending: true })
        .limit(8);
      if (!saved?.length) continue;

      const { data: ranked } = await supabase
        .from("rankings").select("movie_id").eq("user_id", userID);
      const isRanked = new Set((ranked ?? []).map((r: any) => r.movie_id));
      const { data: nudged } = await supabase
        .from("rate_nudges").select("movie_id").eq("user_id", userID);
      const wasNudged = new Set((nudged ?? []).map((n: any) => n.movie_id));

      for (const row of saved) {
        if (isRanked.has(row.movie_id) || wasNudged.has(row.movie_id)) continue;
        if (!(row.movies as any)?.title) continue;
        const res = await fetch(
          `https://api.themoviedb.org/3${tmdbPath(row.movie_id, "/watch/providers")}?api_key=${key}`,
        );
        if (!res.ok) continue;
        const providers = await res.json();
        if (!(providers?.results?.US?.flatrate ?? []).length) continue;
        // Record first so a crash can't double-notify.
        const { error } = await supabase.from("rate_nudges")
          .insert({ user_id: userID, movie_id: row.movie_id });
        if (error) continue;
        await supabase.from("notifications").insert({
          recipient_id: userID, kind: "rate_nudge", movie_id: row.movie_id,
        });
        rateNudged++;
        break;   // one per user per run
      }
    }

    return new Response(JSON.stringify({ streamingNotified, seasonNotified, rateNudged }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("availability-alerts:", e);
    return new Response("skipped", { status: 200 });
  }
});
