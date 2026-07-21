// indie-showtimes: 6-hourly cron. Reads each independent theater's PUBLIC
// calendar directly and normalizes it into supplemental_showtimes — the
// same horizon their own box office sells, weeks past what Gracenote's
// syndication feed carries for indie venues (verified: Metrograph's feed
// in Gracenote ends ~3 days out while their site sells 6+ days ahead).
//
// Adapter contract: return [] on ANY fetch/parse failure — the venue's
// previous rows are then KEPT (stale beats empty), and a loud console
// error marks the site markup as changed. Times are venue-local
// 'YYYY-MM-DDTHH:MM', matching Gracenote's dateTime shape.

import { createClient } from "jsr:@supabase/supabase-js@2";

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
);

const UA =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";

type Row = {
  venue_id: string;
  title: string;
  release_year: number | null;
  format: string | null;
  starts_at: string;
  ticket_url: string | null;
};

async function fetchText(url: string): Promise<string | null> {
  try {
    const res = await fetch(url, {
      headers: { "User-Agent": UA, "Accept": "text/html" },
    });
    if (!res.ok) {
      console.error(`indie-showtimes fetch ${url}: HTTP ${res.status}`);
      return null;
    }
    return await res.text();
  } catch (e) {
    console.error(`indie-showtimes fetch ${url}:`, e);
    return null;
  }
}

function decodeEntities(s: string): string {
  return s
    .replace(/<[^>]+>/g, "")
    .replace(/&amp;/g, "&")
    .replace(/&#0?39;|&#8217;|&rsquo;/g, "'")
    .replace(/&#8216;|&lsquo;/g, "'")
    .replace(/&quot;|&#8220;|&#8221;|&ldquo;|&rdquo;/g, '"')
    .replace(/&eacute;/gi, "é")
    .replace(/&iacute;/gi, "í")
    .replace(/&nbsp;/g, " ")
    .replace(/\s+/g, " ")
    .trim();
}

// "9:15pm" / "7:00 PM" / "12:30(OC)" / bare "2:20" (theaters: 1-9 with no
// suffix are PM, 10-12 are matinee/noon) -> "HH:MM" or null.
function to24h(raw: string): string | null {
  const m = raw.trim().match(/^(\d{1,2}):(\d{2})\s*([ap]\.?m\.?)?/i);
  if (!m) return null;
  let h = parseInt(m[1]);
  if (h < 1 || h > 12 || parseInt(m[2]) > 59) return null;
  const ap = m[3]?.toLowerCase();
  if (ap?.startsWith("p") && h !== 12) h += 12;
  if (ap?.startsWith("a") && h === 12) h = 0;
  if (!ap && h >= 1 && h <= 9) h += 12;
  return `${String(h).padStart(2, "0")}:${m[2]}`;
}

// Today's date in the venues' timezone (all v1 venues are New York).
function nyToday(): Date {
  const s = new Date().toLocaleDateString("en-CA", { timeZone: "America/New_York" });
  return new Date(`${s}T12:00:00Z`);
}
function isoDay(d: Date): string {
  return d.toISOString().slice(0, 10);
}
function addDays(d: Date, n: number): Date {
  return new Date(d.getTime() + n * 86400e3);
}

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6,
  jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

// "Jul 21" / "July  2" -> 'YYYY-MM-DD', inferring the year from the NY
// clock (a January page mentioning December is last month, not next year;
// a December page mentioning January is next year).
function resolveMonthDay(monthName: string, day: number): string | null {
  const mo = MONTHS[monthName.slice(0, 3).toLowerCase()];
  if (!mo || day < 1 || day > 31) return null;
  const today = nyToday();
  let year = today.getUTCFullYear();
  const nowMo = today.getUTCMonth() + 1;
  if (mo === 1 && nowMo === 12) year += 1;
  if (mo === 12 && nowMo === 1) year -= 1;
  return `${year}-${String(mo).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

// ---- Metrograph: /calendar/ has id="calendar-list-day-YYYY-MM-DD"
// sections; items carry "Director / 1992 / 127min / 35mm" metadata and
// per-showtime Vista ticket links.
async function metrograph(): Promise<Row[]> {
  const html = await fetchText("https://metrograph.com/calendar/");
  if (!html) return [];
  const rows: Row[] = [];
  const marks: { date: string; idx: number }[] = [];
  const dayRe = /id="calendar-list-day-(\d{4}-\d{2}-\d{2})"/g;
  let m;
  while ((m = dayRe.exec(html))) marks.push({ date: m[1], idx: m.index });
  for (let i = 0; i < marks.length; i++) {
    const seg = html.slice(marks[i].idx, marks[i + 1]?.idx ?? html.length);
    for (const item of seg.split(/class="item film-thumbnail/).slice(1)) {
      const title = item.match(/class="title">([^<]+)</)?.[1];
      if (!title) continue;
      const meta = item.match(/film-metadata">([^<]*)</)?.[1] ?? "";
      const year = meta.match(/\b(19|20)\d{2}\b/)?.[0];
      const fmt = meta.match(/\b(35\s?mm|16\s?mm|70\s?mm|4K)\b/i)?.[0] ?? null;
      const showtimes = item.match(/class="showtimes">([\s\S]*?)<\/div>/)?.[1] ?? "";
      // Sold-out screenings render as <a class="sold_out"> with NO href —
      // they still PLAY, so they still mark the calendar (ticket_url null).
      const timeRe = /<a (?:href="([^"]+)"[^>]*|class="sold_out"[^>]*)>\s*([\d:]+\s*[ap]m)/gi;
      let t;
      while ((t = timeRe.exec(showtimes))) {
        const hm = to24h(t[2]);
        if (!hm) continue;
        rows.push({
          venue_id: "metrograph",
          title: decodeEntities(title),
          release_year: year ? +year : null,
          format: fmt,
          starts_at: `${marks[i].date}T${hm}`,
          ticket_url: t[1] ? t[1].replace(/&amp;/g, "&") : null,
        });
      }
    }
  }
  return rows;
}

// ---- Film Forum: /now_playing has id="tabs-0..6" day sections, each
// opening with an HTML comment naming the day of month (<!-- 21 -->).
// Times are bare "12:15"/"8:50" spans; the film link is the ticket target.
async function filmforum(): Promise<Row[]> {
  const html = await fetchText("https://filmforum.org/now_playing");
  if (!html) return [];
  const rows: Row[] = [];
  const today = nyToday();
  for (let d = 0; d <= 6; d++) {
    const startTag = `id="tabs-${d}"`;
    const s = html.indexOf(startTag);
    if (s < 0) continue;
    const e = html.indexOf(`id="tabs-${d + 1}"`, s);
    const seg = html.slice(s, e > 0 ? e : s + 20000);
    // Prefer the page's own day-of-month comment over index arithmetic —
    // their "today" tab can roll after the last evening show.
    const domMatch = seg.match(/<!--\s*(\d{1,2})\s*-->/);
    let date: string | null = null;
    if (domMatch) {
      const dom = +domMatch[1];
      for (let off = 0; off <= 8; off++) {
        const cand = addDays(today, off);
        if (cand.getUTCDate() === dom) { date = isoDay(cand); break; }
      }
    }
    date ??= isoDay(addDays(today, d));
    const filmRe = /<a href="(https:\/\/filmforum\.org\/film\/[^"]+)">([^<]+)<\/a><\/strong>([\s\S]*?)<\/p>/g;
    let f;
    while ((f = filmRe.exec(seg))) {
      const title = decodeEntities(f[2]);
      const timeRe = /<span>([\d:]+)[^<]*<\/span>/g;
      let t;
      while ((t = timeRe.exec(f[3]))) {
        const hm = to24h(t[1]);
        if (!hm) continue;
        rows.push({
          venue_id: "filmforum", title, release_year: null, format: null,
          starts_at: `${date}T${hm}`, ticket_url: f[1],
        });
      }
    }
  }
  return rows;
}

// ---- IFC Center: homepage has class="daily-schedule <dow>" sections with
// <h3>Tue Jul 21</h3> headers; films carry per-showtime ticket links.
async function ifc(): Promise<Row[]> {
  const html = await fetchText("https://www.ifccenter.com/");
  if (!html) return [];
  const rows: Row[] = [];
  const parts = html.split(/class="daily-schedule /).slice(1);
  for (const part of parts) {
    const head = part.match(/<h3>\s*\w{3}\s+(\w{3,9})\s+(\d{1,2})\s*<\/h3>/);
    if (!head) continue;
    const date = resolveMonthDay(head[1], +head[2]);
    if (!date) continue;
    const filmRe = /<h3><a href="[^"]*">([^<]+)<\/a><\/h3>\s*<ul class="times">([\s\S]*?)<\/ul>/g;
    let f;
    while ((f = filmRe.exec(part))) {
      const title = decodeEntities(f[1]);
      const timeRe = /<a href="([^"]+)"\s*>\s*([\d:]+\s*[AP]M)/gi;
      let t;
      while ((t = timeRe.exec(f[2]))) {
        const hm = to24h(t[2]);
        if (!hm) continue;
        rows.push({
          venue_id: "ifc", title, release_year: null, format: null,
          starts_at: `${date}T${hm}`,
          ticket_url: t[1].replace(/&amp;|&#0?38;/g, "&").trim(),
        });
      }
    }
  }
  return rows;
}

// ---- Anthology Film Archives: month list view with "Thursday, July  2"
// headers and film-showing entries ("6:45 PM", title span, "1956, 84 min,
// 35mm"). Fetch this month and next.
async function anthology(): Promise<Row[]> {
  const today = nyToday();
  const months = [today, addDays(today, 28)];
  const rows: Row[] = [];
  const seenMonths = new Set<number>();
  for (const d of months) {
    const mo = d.getUTCMonth() + 1;
    if (seenMonths.has(mo)) continue;
    seenMonths.add(mo);
    const html = await fetchText(
      `http://anthologyfilmarchives.org/film_screenings/calendar?view=list&month=${mo}`,
    );
    if (!html) continue;
    const dayRe = /([A-Z][a-z]+day),?\s+([A-Z][a-z]+)\s+(\d{1,2})/g;
    const marks: { date: string; idx: number }[] = [];
    let m;
    while ((m = dayRe.exec(html))) {
      const date = resolveMonthDay(m[2], +m[3]);
      if (date) marks.push({ date, idx: m.index });
    }
    for (let i = 0; i < marks.length; i++) {
      const seg = html.slice(marks[i].idx, marks[i + 1]?.idx ?? html.length);
      const showRe = /<a name="showing-\d+">\s*([\d:]+\s*[AP]M)<\/a>[\s\S]*?film-title">([^<]+)<[\s\S]*?((?:19|20)\d{2}),\s*\d+\s*min(?:,\s*([\w\s]+?))?\s*</g;
      let sh;
      while ((sh = showRe.exec(seg))) {
        const hm = to24h(sh[1]);
        if (!hm) continue;
        rows.push({
          venue_id: "anthology",
          title: decodeEntities(sh[2]),
          release_year: +sh[3],
          format: sh[4]?.trim() || null,
          starts_at: `${marks[i].date}T${hm}`,
          ticket_url: "http://anthologyfilmarchives.org/film_screenings/calendar",
        });
      }
    }
  }
  return rows;
}

Deno.serve(async (_req: Request) => {
  const adapters: [string, () => Promise<Row[]>][] = [
    ["metrograph", metrograph],
    ["filmforum", filmforum],
    ["ifc", ifc],
    ["anthology", anthology],
  ];
  const counts: Record<string, number> = {};
  for (const [venue, run] of adapters) {
    let rows: Row[] = [];
    try {
      rows = await run();
    } catch (e) {
      console.error(`indie-showtimes ${venue} adapter threw:`, e);
    }
    // De-dupe within the run (pk is venue+title+time).
    const seen = new Set<string>();
    rows = rows.filter((r) => {
      const k = `${r.title}|${r.starts_at}`;
      if (seen.has(k)) return false;
      seen.add(k);
      return true;
    });
    counts[venue] = rows.length;
    if (!rows.length) {
      // Parse/fetch failure: KEEP the previous rows (stale beats empty) and
      // shout — an empty result usually means the site's markup changed.
      console.error(`indie-showtimes ${venue}: 0 rows parsed — keeping previous data`);
      continue;
    }
    const { error: delErr } = await supabase
      .from("supplemental_showtimes").delete().eq("venue_id", venue);
    if (delErr) {
      console.error(`indie-showtimes ${venue} delete:`, delErr);
      continue;
    }
    for (let i = 0; i < rows.length; i += 200) {
      const { error } = await supabase
        .from("supplemental_showtimes").insert(rows.slice(i, i + 200));
      if (error) console.error(`indie-showtimes ${venue} insert:`, error);
    }
  }
  // Prune anything past (keeps the table tiny).
  const cutoff = isoDay(addDays(nyToday(), -1));
  await supabase.from("supplemental_showtimes").delete().lt("starts_at", cutoff);
  return new Response(JSON.stringify(counts), {
    headers: { "Content-Type": "application/json" },
  });
});
