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

// PostgREST caps every response at 1,000 rows — page with .range so alerts
// don't silently stop for users/titles past row 1000.
async function allRows(build: (from: number, to: number) => any): Promise<any[]> {
  const out: any[] = [];
  for (let from = 0; ; from += 1000) {
    const { data, error } = await build(from, from + 999);
    if (error) { console.error("paginate:", error); break; }
    if (!data?.length) break;
    out.push(...data);
    if (data.length < 1000) break;
  }
  return out;
}

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
    const alerts = await allRows((f, t) => supabase
      .from("streaming_alerts")
      .select("user_id, movie_id")
      .is("notified_at", null)
      .range(f, t));
    const byMovie = new Map<number, string[]>();
    for (const a of alerts) {
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
        // If the notification row doesn't land, un-mark the alert so the
        // next run retries — otherwise the one-shot alert vanishes.
        const { data: ins, error: nErr } = await supabase.from("notifications").insert({
          recipient_id: userID,
          kind: "streaming_now",
          movie_id: movieID,
        }).select("id");
        if (nErr || !ins?.length) {
          if (nErr) console.error("availability-alerts streaming insert:", nErr);
          await supabase.from("streaming_alerts")
            .update({ notified_at: null })
            .eq("user_id", userID).eq("movie_id", movieID);
          continue;
        }
        streamingNotified++;
      }
    }

    // ---- 2. Season premieres for ranked shows ----
    const tvRankings = await allRows((f, t) => supabase
      .from("rankings")
      .select("user_id, movie_id")
      .lt("movie_id", 0)
      .range(f, t));
    const byShow = new Map<number, string[]>();
    for (const r of tvRankings) {
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
        const { data: ins, error: nErr } = await supabase.from("notifications").insert({
          recipient_id: userID,
          kind: "season_premiere",
          movie_id: showID,
        }).select("id");
        if (nErr || !ins?.length) {
          if (nErr) console.error("availability-alerts season insert:", nErr);
          await supabase.from("season_notices").delete()
            .eq("user_id", userID).eq("movie_id", showID)
            .eq("season", next.season_number);
          continue;
        }
        seasonNotified++;
      }
    }

    // ---- 3. Rate nudges: "seen it yet? rank it" ----
    // For each pushable user, take their OLDEST unranked Want-to-Watch
    // title on the list 10+ days and not yet nudged; if it's streamable
    // in the US, nudge once. Rate-limited to one per user per ~3 days,
    // one TMDB call per user per run, one nudge per title ever.
    let rateNudged = 0;
    const tokens2 = await allRows((f, t) => supabase
      .from("device_tokens").select("user_id").range(f, t));
    const pushable = [...new Set(tokens2.map((t: any) => t.user_id))];
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

      const ranked = await allRows((f, t) => supabase
        .from("rankings").select("movie_id").eq("user_id", userID).range(f, t));
      const isRanked = new Set(ranked.map((r: any) => r.movie_id));
      const nudged = await allRows((f, t) => supabase
        .from("rate_nudges").select("movie_id").eq("user_id", userID).range(f, t));
      const wasNudged = new Set(nudged.map((n: any) => n.movie_id));

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
        const { data: ins, error: nErr } = await supabase.from("notifications").insert({
          recipient_id: userID, kind: "rate_nudge", movie_id: row.movie_id,
        }).select("id");
        if (nErr || !ins?.length) {
          if (nErr) console.error("availability-alerts nudge insert:", nErr);
          await supabase.from("rate_nudges").delete()
            .eq("user_id", userID).eq("movie_id", row.movie_id);
          continue;
        }
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
