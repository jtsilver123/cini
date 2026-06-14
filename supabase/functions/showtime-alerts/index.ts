// showtime-alerts: daily cron. Tells users when a watchlist movie is
// playing near their saved zip — at ANY age (a decades-old re-release
// counts, not just new releases).
//
// API frugality: exactly ONE Gracenote call per DISTINCT zip per run,
// regardless of user count. Each user is notified at most once per movie
// ever (showtime_notices), and delivery rides the normal notifications
// table -> trigger -> send-push pipeline.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

// ---- fuzzy title match (mirrors the app's FuzzyMatch.swift) ----
function editDistance(a: string, b: string): number {
  const m = a.length, n = b.length;
  if (!m) return n;
  if (!n) return m;
  let prev2 = new Array(n + 1).fill(0);
  let prev = Array.from({ length: n + 1 }, (_, j) => j);
  let cur = new Array(n + 1).fill(0);
  for (let i = 1; i <= m; i++) {
    cur[0] = i;
    for (let j = 1; j <= n; j++) {
      cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] === b[j - 1] ? 0 : 1));
      if (i > 1 && j > 1 && a[i - 1] === b[j - 2] && a[i - 2] === b[j - 1]) {
        cur[j] = Math.min(cur[j], prev2[j - 2] + 1);
      }
    }
    [prev2, prev, cur] = [prev, cur, prev2];
  }
  return prev[n];
}

function similarity(q: string, c: string): number {
  q = q.toLowerCase().trim();
  c = c.toLowerCase().trim();
  if (!q || !c) return 0;
  return 1 - editDistance(q, c) / Math.max(q.length, c.length);
}

const norm = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

Deno.serve(async (_req: Request) => {
  try {
    const { data: secrets } = await supabase.rpc("get_apns_secrets");
    const gnKey = (secrets ?? []).find((s: any) => s.name === "GRACENOTE_API_KEY")?.secret;
    if (!gnKey) return new Response("no gracenote key", { status: 200 });

    // Users who can receive alerts: saved zip AND a registered device.
    // ZIPs live in the private user_locations table (service role reads it).
    const { data: locations } = await supabase
      .from("user_locations")
      .select("user_id, home_zip")
      .not("home_zip", "is", null);
    if (!locations?.length) return new Response("no users with zips", { status: 200 });
    const profiles = locations.map((l: any) => ({ id: l.user_id, home_zip: l.home_zip }));

    const { data: tokens } = await supabase.from("device_tokens").select("user_id");
    const pushable = new Set((tokens ?? []).map((t: any) => t.user_id));
    const candidates = profiles.filter((p: any) => pushable.has(p.id));
    if (!candidates.length) return new Response("no pushable users", { status: 200 });

    const userIDs = candidates.map((p: any) => p.id);
    const { data: watchlists } = await supabase
      .from("watchlist")
      .select("user_id, movie_id, movies(title, release_year, media_kind)")
      .in("user_id", userIDs);
    const { data: noticed } = await supabase
      .from("showtime_notices")
      .select("user_id, movie_id")
      .in("user_id", userIDs);
    const alreadyNoticed = new Set((noticed ?? []).map((n: any) => `${n.user_id}:${n.movie_id}`));

    // One Gracenote request per DISTINCT zip.
    const byZip = new Map<string, any[]>();
    for (const p of candidates) {
      if (!byZip.has(p.home_zip)) byZip.set(p.home_zip, []);
      byZip.get(p.home_zip)!.push(p);
    }

    const today = new Date().toISOString().slice(0, 10);
    let notified = 0;

    for (const [zip, users] of byZip) {
      const url = `https://data.tmsapi.com/v1.1/movies/showings?startDate=${today}&zip=${zip}&radius=15&units=mi&api_key=${gnKey}`;
      const res = await fetch(url);
      if (!res.ok) continue;
      const playing: { title: string; releaseYear?: number }[] = await res.json();

      for (const user of users) {
        const entries = (watchlists ?? []).filter((w: any) => w.user_id === user.id);
        for (const entry of entries) {
          const movie = entry.movies as any;
          if (!movie?.title) continue;
          // TV shows don't play in theaters — skip them.
          if (movie.media_kind === "tv") continue;
          if (alreadyNoticed.has(`${user.id}:${entry.movie_id}`)) continue;

          // Any watchlist movie playing near you, no matter its age — a
          // decades-old re-release counts. The year only disambiguates
          // remakes on a FUZZY title; an exact-title screening matches
          // outright even if the listing's year is the re-release year.
          const hit = playing.some((p) => {
            const sim = similarity(movie.title, p.title);
            if (sim <= 0.85) return false;
            if (norm(movie.title) === norm(p.title)) return true;
            return !movie.release_year || !p.releaseYear ||
                   Math.abs(movie.release_year - p.releaseYear) <= 1;
          });
          if (!hit) continue;

          // Record first so a crash can't double-notify, then let the
          // notifications trigger handle bell + push delivery.
          const { error: noticeError } = await supabase
            .from("showtime_notices")
            .insert({ user_id: user.id, movie_id: entry.movie_id });
          if (noticeError) continue;
          await supabase.from("notifications").insert({
            recipient_id: user.id,
            kind: "watchlist_showing",
            movie_id: entry.movie_id,
          });
          notified++;
        }
      }
    }

    return new Response(JSON.stringify({ zips: byZip.size, notified }), {
      headers: { "Content-Type": "application/json" },
    });
  } catch (e) {
    console.error("showtime-alerts:", e);
    return new Response("skipped", { status: 200 });
  }
});
