// showtime-alerts: HOURLY cron. Tells users the moment tickets for a
// watchlist movie go on sale near their saved zip — at ANY age (a
// decades-old re-release counts), and with a VERY LARGE look-ahead:
// advance sales (IMAX pre-sales weeks out) fire the alert as soon as
// Gracenote lists them, because those are exactly the tickets that sell
// out.
//
// API frugality vs instantness: every hourly run scans the next 14 days
// (one call per DISTINCT zip); four runs a day extend the sweep out to
// ~70 days (four extra calls per zip). Near-term on-sales alert within
// the hour; far-future ones within six. Each user is notified at most
// once per movie ever (showtime_notices), and delivery rides the normal
// notifications table -> trigger -> send-push pipeline.

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

// Gracenote lists premium screenings as SEPARATE title variants ("Dune:
// Part Two: The IMAX 2D Experience", "Oppenheimer 70mm", "Casablanca (80th
// Anniversary)"). Strip the dressing so they match the watchlist title —
// without this the alert never fires for exactly the screenings people
// most want to hear about. Mirrors ShowtimesService.canonicalTitle.
// \b before each format token: without it "Climax" ends in "imax" and
// canonicalizes to "Cl" — a real film whose alert would never fire.
const VARIANT_PATTERNS = [
  /[:\-–—]?\s*((the|an?)\s+)?\bimax(\s+(2d|3d|70mm|laser))?(\s+experience)?\s*$/i,
  /[:\-–—]?\s*(an?\s+)?\b(imax|4dx|screenx|rpx|dolby(\s+(cinema|atmos))?)\s*(experience)?\s*$/i,
  /[:\-–—]?\s*(in\s+)?\b(3d|70\s?mm|35\s?mm)\s*$/i,
  /[:\-–—]?\s*\(?\b\d+(th|st|nd|rd)\s+anniversary\)?\s*$/i,
  /[:\-–—]?\s*\(?\b(re-?release|remastered|restoration|extended\s+(edition|version|cut)|director'?s\s+cut)\)?\s*$/i,
  /\s*\(\d{4}\)\s*$/,
];
// "today" / "tomorrow" / "Fri, Jul 24" — when the first showing is.
function datePhrase(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return "";
  const today = new Date(); today.setHours(0, 0, 0, 0);
  const that = new Date(d); that.setHours(0, 0, 0, 0);
  const diff = Math.round((that.getTime() - today.getTime()) / 86400e3);
  if (diff <= 0) return "today";
  if (diff === 1) return "tomorrow";
  return d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
}

function canonicalTitle(raw: string): string {
  let title = raw;
  let changed = true;
  while (changed) {
    changed = false;
    for (const pattern of VARIANT_PATTERNS) {
      const stripped = title.replace(pattern, "");
      if (stripped !== title && stripped.trim().length) {
        title = stripped;
        changed = true;
      }
    }
  }
  return title.replace(/[\s:\-–—]+$/, "").trim();
}

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

    let notified = 0;
    // Window offsets (days from today), each fetched with numDays=14. The
    // near-term window runs EVERY hour; the far windows join four times a
    // day (hours 4/10/16/22 UTC) to keep Gracenote usage bounded.
    const fullSweep = new Date().getUTCHours() % 6 === 4;
    const offsets = fullSweep ? [0, 14, 28, 42, 56] : [0];

    for (const [zip, users] of byZip) {
      const playing: { title: string; releaseYear?: number; earliest: string | null }[] = [];
      const seenListing = new Map<string, number>();
      for (const offset of offsets) {
        const start = new Date(Date.now() + offset * 86400e3).toISOString().slice(0, 10);
        const url = `https://data.tmsapi.com/v1.1/movies/showings?startDate=${start}&numDays=14&zip=${zip}&radius=15&units=mi&api_key=${gnKey}`;
        const res = await fetch(url);
        if (!res.ok) continue;
        // One malformed/empty window response (transient rate limiting
        // returns 200 with an empty body) must not abort the whole sweep.
        let chunk: unknown;
        try { chunk = await res.json(); } catch { continue; }
        if (!Array.isArray(chunk)) continue;
        for (const listing of chunk) {
          // Earliest showing across this listing's showtimes — the alert
          // says WHEN, not just that tickets exist. ISO-ish local strings
          // ("2026-07-24T19:30") compare correctly as text.
          let earliest: string | null = null;
          for (const showing of listing.showtimes ?? []) {
            const at = showing?.dateTime;
            if (typeof at === "string" && at && (!earliest || at < earliest)) earliest = at;
          }
          const key = `${listing.title}|${listing.releaseYear ?? ""}`;
          const existing = seenListing.get(key);
          if (existing !== undefined) {
            // Same variant seen in an earlier window — keep the sooner date.
            const kept = playing[existing];
            if (earliest && (!kept.earliest || earliest < kept.earliest)) kept.earliest = earliest;
            continue;
          }
          seenListing.set(key, playing.length);
          playing.push({ title: listing.title, releaseYear: listing.releaseYear, earliest });
        }
      }
      if (!playing.length) continue;

      for (const user of users) {
        const entries = (watchlists ?? []).filter((w: any) => w.user_id === user.id);
        for (const entry of entries) {
          const movie = entry.movies as any;
          if (!movie?.title) continue;
          // TV shows don't play in theaters — skip them.
          if (movie.media_kind === "tv") continue;
          if (alreadyNoticed.has(`${user.id}:${entry.movie_id}`)) continue;

          // Any watchlist movie playing near you, no matter its age — a
          // decades-old re-release counts. Listings compare by their
          // CANONICAL title (variant dressing stripped) so "…: The IMAX
          // Experience" screenings fire the alert too. The year only
          // disambiguates remakes on a FUZZY title; an exact-title
          // screening matches outright even if the listing's year is the
          // re-release year.
          let hit = false;
          let earliest: string | null = null;
          for (const p of playing) {
            const candidate = canonicalTitle(p.title);
            // Exact normalized match FIRST — punctuation-heavy titles
            // ("WALL·E" vs "WALL-E") have low edit-distance similarity and
            // must not be lost behind the fuzzy gate.
            let match = norm(movie.title) === norm(candidate);
            if (!match) {
              const sim = similarity(movie.title, candidate);
              match = sim > 0.85 && (!movie.release_year || !p.releaseYear ||
                     Math.abs(movie.release_year - p.releaseYear) <= 1);
            }
            if (!match) continue;
            hit = true;
            if (p.earliest && (!earliest || p.earliest < earliest)) earliest = p.earliest;
          }
          if (!hit) continue;

          // Record first so a crash can't double-notify, then let the
          // notifications trigger handle bell + push delivery. The message
          // carries WHEN — "First showing Fri, Jul 24" — because these
          // tickets sell out and urgency needs a date.
          const phrase = earliest ? datePhrase(earliest) : "";
          const { error: noticeError } = await supabase
            .from("showtime_notices")
            .insert({ user_id: user.id, movie_id: entry.movie_id });
          if (noticeError) continue;
          await supabase.from("notifications").insert({
            recipient_id: user.id,
            kind: "watchlist_showing",
            movie_id: entry.movie_id,
            message: phrase ? `First showing ${phrase}` : null,
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
