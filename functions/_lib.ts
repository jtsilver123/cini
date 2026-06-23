// Shared helpers for the Cloudflare Pages Functions that SERVER-RENDER the
// public web pages (/u, /m, /l) with real per-entity <head> meta + content.
// Why this exists: GitHub Pages can only serve fixed files, so the static
// /u/?u= etc. pages build themselves in the browser — which means link
// unfurls (iMessage/social) and search crawlers see a generic shell. These
// Functions render the real title/description/image + content per request, so
// shared links become rich cards and pages are crawlable. They mount at the
// SAME query-param paths the app already links to (/u/?u=, /m/?id=, /l/?id=),
// so once this is deployed on Cloudflare no app change is needed.
//
// NOTE: this code runs only on Cloudflare Pages — it cannot be exercised in CI
// or the iOS build. Verify after the first deploy (see docs/CLOUDFLARE_DEPLOY.md).

export const SUPABASE_URL = "https://npumchnkbcajyuhurgez.supabase.co";
// Publishable anon key — the same one the app and the static pages ship. It is
// NOT a secret: every public_* RPC is SECURITY DEFINER and scoped to non-private
// data, and RLS protects everything else.
export const ANON =
  "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Im5wdW1jaG5rYmNhanl1aHVyZ2V6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODExMDgxMTAsImV4cCI6MjA5NjY4NDExMH0.DahwElvj1oqZRbQbnocmxVm8Yb1y2i61tuLBW8AV4h8";
export const APP_STORE =
  "https://apps.apple.com/us/app/cini-rank-every-film/id6778975898";
export const OG_FALLBACK = "https://trycini.com/og.png";

export async function rpc<T = unknown>(
  fn: string,
  body: Record<string, unknown>,
): Promise<T | null> {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: "POST",
      headers: {
        apikey: ANON,
        Authorization: `Bearer ${ANON}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify(body),
    });
    if (!res.ok) return null;
    return (await res.json()) as T;
  } catch {
    return null;
  }
}

const ENT: Record<string, string> = {
  "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
};
/** Escape for HTML text AND attribute contexts. */
export function esc(s: unknown): string {
  return String(s ?? "").replace(/[&<>"']/g, (c) => ENT[c]);
}

/** A TMDB image URL from a stored path, or null. Sanitized. */
export function tmdb(path: unknown, size: string): string | null {
  if (!path || typeof path !== "string") return null;
  return `https://image.tmdb.org/t/p/${size}${path.replace(/[^A-Za-z0-9/_.\-]/g, "")}`;
}

/** Only allow https URLs through (avatar_url comes from storage). */
export function safeHttps(u: unknown): string | null {
  return typeof u === "string" && /^https:\/\//i.test(u) ? u : null;
}

export function scoreColor(s: number): string {
  return s >= 8.5 ? "#3FB55A" : s >= 7 ? "#E8B64C" : s >= 5 ? "#C9A24B" : "#A8352A";
}

const BASE_CSS = `
:root{--marquee:#E8B64C;--velvet:#A8352A;--ink:#F5EEDF;--bg:#131011;--surface:#1D1719;--surface2:#262022;--gray:#A69C91;--hair:rgba(255,255,255,.12);--green:#3FB55A;}
*{box-sizing:border-box;margin:0;}
body{min-height:100vh;color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;background:radial-gradient(70% 40% at 50% 0%, rgba(232,182,76,.12), transparent 70%), var(--bg);padding:0 16px 60px;}
a{color:inherit;text-decoration:none;}
.wrap{max-width:760px;margin:0 auto;}
.topbar{display:flex;align-items:center;justify-content:space-between;padding:20px 0 8px;}
.wordmark{font-family:"Limelight",Georgia,serif;font-size:30px;color:var(--marquee);}
.getcini{font-weight:700;font-size:13px;padding:9px 16px;border-radius:999px;background:var(--velvet);color:#fff;}
.name{font-family:"DM Serif Display",Georgia,serif;font-weight:400;font-size:30px;line-height:1.1;}
.title{font-family:"DM Serif Display",Georgia,serif;font-weight:400;font-size:32px;line-height:1.1;}
.sub{color:var(--gray);font-size:14px;margin-top:6px;}
.bio{font-size:15px;line-height:1.5;margin:14px 0 6px;}
.head{display:flex;gap:18px;align-items:center;margin-top:6px;}
.avatar{width:88px;height:88px;border-radius:50%;object-fit:cover;background:var(--surface2);flex:none;display:flex;align-items:center;justify-content:center;font-family:"DM Serif Display",serif;font-size:34px;color:var(--marquee);}
.stats{display:flex;gap:22px;margin:16px 0 4px;flex-wrap:wrap;}
.stat b{font-size:18px;} .stat span{color:var(--gray);font-size:13px;margin-left:5px;}
.divider{height:1px;background:var(--hair);margin:22px 0 18px;}
.seg{font-size:11px;letter-spacing:.22em;color:var(--gray);font-weight:800;margin:0 0 14px;}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(96px,1fr));gap:16px 12px;}
.card .poster{width:100%;aspect-ratio:2/3;border-radius:10px;background:var(--surface2) center/cover no-repeat;box-shadow:0 6px 16px rgba(0,0,0,.35);position:relative;}
.badge{position:absolute;top:6px;right:6px;background:rgba(0,0,0,.66);border-radius:8px;font-size:12px;font-weight:800;padding:3px 7px;}
.ptitle{font-size:12px;font-weight:600;margin-top:6px;line-height:1.25;}
.pyear{font-size:11px;color:var(--gray);}
.lists{display:flex;gap:10px;flex-wrap:wrap;}
.listchip{display:flex;align-items:center;gap:8px;border:1px solid var(--hair);border-radius:999px;padding:8px 14px;}
.lname{font-size:13px;font-weight:600;} .lcount{font-size:11px;color:var(--bg);background:var(--marquee);border-radius:999px;padding:1px 7px;font-weight:800;}
.foot{text-align:center;margin-top:36px;}
.foot a{font-weight:700;font-size:15px;padding:14px 26px;border-radius:999px;background:var(--velvet);color:#fff;display:inline-block;box-shadow:0 10px 26px rgba(168,53,42,.3);}
.foot p{color:var(--gray);font-size:12.5px;margin-top:14px;}
.overview{font-size:15px;line-height:1.6;margin:20px 0;opacity:.92;}
.genres{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0;}
.chip{font-size:12px;color:var(--gray);border:1px solid var(--hair);border-radius:999px;padding:5px 11px;}
.score{display:flex;align-items:center;gap:16px;margin:24px 0 8px;}
.scorenum{font-family:"DM Serif Display",serif;font-size:46px;line-height:1;}
.msg{text-align:center;color:var(--gray);padding:64px 16px;font-size:16px;line-height:1.6;}
`;

/** Render the shared HTML shell with full per-page <head> meta. */
export function shell(opts: {
  title: string;
  description: string;
  canonical: string;
  ogImage: string;
  ogType?: string;
  jsonLd?: object;
  noindex?: boolean;
  bodyHtml: string;
}): Response {
  const { title, description, canonical, ogImage, ogType = "website", jsonLd, noindex, bodyHtml } = opts;
  const html = `<!DOCTYPE html><html lang="en"><head>
<meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0">
<meta name="theme-color" content="#131011">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<link rel="canonical" href="${esc(canonical)}">
${noindex ? '<meta name="robots" content="noindex">' : ""}
<meta property="og:type" content="${esc(ogType)}">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${esc(canonical)}">
<meta property="og:image" content="${esc(ogImage)}">
<meta name="twitter:card" content="summary_large_image">
<meta name="twitter:title" content="${esc(title)}">
<meta name="twitter:description" content="${esc(description)}">
<meta name="twitter:image" content="${esc(ogImage)}">
${jsonLd ? `<script type="application/ld+json">${JSON.stringify(jsonLd)}</script>` : ""}
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display&family=Limelight&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="/favicon.png">
<style>${BASE_CSS}</style>
</head><body><div class="wrap">
<div class="topbar"><a class="wordmark" href="/">cini</a><a class="getcini" href="${APP_STORE}">Get Cini</a></div>
${bodyHtml}
</div></body></html>`;
  return new Response(html, {
    headers: {
      "content-type": "text/html; charset=utf-8",
      // Cache at the edge briefly so crawlers/refreshes are cheap, but updates
      // (a new rank, a new list) show within minutes.
      "cache-control": "public, max-age=120, s-maxage=300",
    },
  });
}

export function notFoundPage(message: string): Response {
  return shell({
    title: "Not available — Cini",
    description: "This page isn’t available on Cini.",
    canonical: "https://trycini.com/",
    ogImage: OG_FALLBACK,
    noindex: true,
    bodyHtml: `<div class="msg">${esc(message)}</div>`,
  });
}
