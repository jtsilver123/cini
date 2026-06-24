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
:root{--marquee:#E8B64C;--velvet:#A8352A;--ink:#F5EEDF;--bg:#131011;--surface:#1D1719;--surface2:#262022;--gray:#A69C91;--hair:rgba(255,255,255,.12);--green:#3FB55A;--ease:cubic-bezier(.22,.61,.36,1);}
*{box-sizing:border-box;margin:0;}
body{min-height:100vh;color:var(--ink);font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;-webkit-font-smoothing:antialiased;text-rendering:optimizeLegibility;background:radial-gradient(70% 38% at 50% 0%, rgba(232,182,76,.13), transparent 70%), var(--bg);}
a{color:inherit;text-decoration:none;}
::selection{background:rgba(232,182,76,.28);color:var(--ink);}
:focus-visible{outline:2px solid var(--marquee);outline-offset:3px;border-radius:8px;}
/* Sticky frosted header */
.hdr{position:sticky;top:0;z-index:50;background:rgba(19,16,17,.72);border-bottom:1px solid var(--hair);-webkit-backdrop-filter:blur(14px) saturate(1.3);backdrop-filter:blur(14px) saturate(1.3);}
.hdr-in{max-width:760px;margin:0 auto;display:flex;align-items:center;justify-content:space-between;padding:13px 16px;}
.wordmark{font-family:"Limelight",Georgia,serif;font-size:28px;color:var(--marquee);transition:filter .2s var(--ease);}
.wordmark:hover{filter:brightness(1.12);}
.getcini{font-weight:700;font-size:13px;padding:9px 16px;border-radius:999px;background:var(--velvet);color:#fff;box-shadow:0 6px 18px rgba(168,53,42,.3);transition:transform .15s var(--ease),box-shadow .15s var(--ease);}
.getcini:hover{transform:translateY(-1px);box-shadow:0 10px 24px rgba(168,53,42,.45);}
.wrap{max-width:760px;margin:0 auto;padding:16px 16px 68px;animation:rise .6s var(--ease) both;}
@keyframes rise{from{opacity:0;transform:translateY(14px);}to{opacity:1;transform:none;}}
.name{font-family:"DM Serif Display",Georgia,serif;font-weight:400;font-size:30px;line-height:1.08;letter-spacing:-.01em;}
.title{font-family:"DM Serif Display",Georgia,serif;font-weight:400;font-size:clamp(28px,5vw,36px);line-height:1.06;letter-spacing:-.01em;}
.sub{color:var(--gray);font-size:14px;margin-top:6px;}
.bio{font-size:15px;line-height:1.55;margin:14px 0 6px;}
.head{display:flex;gap:18px;align-items:center;margin-top:6px;}
.avatar{width:88px;height:88px;border-radius:50%;object-fit:cover;background:var(--surface2);flex:none;display:flex;align-items:center;justify-content:center;font-family:"DM Serif Display",serif;font-size:34px;color:var(--marquee);box-shadow:0 0 0 2px var(--hair),0 8px 22px rgba(0,0,0,.4);}
.stats{display:flex;gap:12px;margin:18px 0 4px;flex-wrap:wrap;}
.stat{background:linear-gradient(180deg,var(--surface),rgba(29,23,25,.55));border:1px solid var(--hair);border-radius:14px;padding:10px 16px;transition:border-color .2s var(--ease),transform .2s var(--ease);}
.stat:hover{border-color:rgba(232,182,76,.4);transform:translateY(-2px);}
.stat b{font-size:18px;} .stat span{color:var(--gray);font-size:13px;margin-left:5px;}
.divider{height:1px;background:var(--hair);margin:24px 0 18px;}
.seg{font-size:11px;letter-spacing:.22em;color:var(--gray);font-weight:800;margin:0 0 14px;}
.grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(100px,1fr));gap:18px 12px;}
.card{transition:transform .12s var(--ease);}
.card:active{transform:scale(.97);}
.card .poster{width:100%;aspect-ratio:2/3;border-radius:12px;background:var(--surface2) center/cover no-repeat;box-shadow:0 6px 16px rgba(0,0,0,.4);position:relative;transition:transform .25s var(--ease),box-shadow .25s var(--ease);}
.card:hover .poster{transform:translateY(-5px) scale(1.025);box-shadow:0 18px 38px rgba(0,0,0,.55);}
.badge{position:absolute;top:6px;right:6px;background:rgba(0,0,0,.68);-webkit-backdrop-filter:blur(4px);backdrop-filter:blur(4px);border-radius:8px;font-size:12px;font-weight:800;padding:3px 7px;}
.ptitle{font-size:12px;font-weight:600;margin-top:7px;line-height:1.25;}
.card:hover .ptitle{color:var(--marquee);}
.pyear{font-size:11px;color:var(--gray);}
.lists{display:flex;gap:10px;flex-wrap:wrap;}
.listchip{display:flex;align-items:center;gap:8px;border:1px solid var(--hair);border-radius:999px;padding:9px 14px;background:linear-gradient(180deg,var(--surface),rgba(29,23,25,.5));transition:border-color .2s var(--ease),transform .2s var(--ease);}
.listchip:hover{border-color:rgba(232,182,76,.45);transform:translateY(-2px);}
.lname{font-size:13px;font-weight:600;} .lcount{font-size:11px;color:var(--bg);background:var(--marquee);border-radius:999px;padding:1px 7px;font-weight:800;}
.foot{text-align:center;margin-top:40px;}
.foot a{font-weight:700;font-size:15px;padding:14px 28px;border-radius:999px;background:var(--velvet);color:#fff;display:inline-block;box-shadow:0 10px 26px rgba(168,53,42,.32);transition:transform .18s var(--ease),box-shadow .18s var(--ease);}
.foot a:hover{transform:translateY(-2px);box-shadow:0 16px 34px rgba(168,53,42,.46);}
.foot p{color:var(--gray);font-size:12.5px;margin-top:14px;}
.overview{font-size:15px;line-height:1.65;margin:20px 0;opacity:.92;}
.genres{display:flex;gap:8px;flex-wrap:wrap;margin:10px 0;}
.chip{font-size:12px;color:var(--gray);border:1px solid var(--hair);border-radius:999px;padding:5px 11px;}
.score{display:flex;align-items:center;gap:16px;margin:24px 0 8px;}
.scorenum{font-family:"DM Serif Display",serif;font-size:48px;line-height:1;text-shadow:0 2px 18px rgba(232,182,76,.18);}
.msg{text-align:center;color:var(--gray);padding:64px 16px;font-size:16px;line-height:1.6;}
@media (prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important;}}
@media (max-width:560px){.head{gap:14px;}.avatar{width:72px;height:72px;font-size:28px;}.grid{grid-template-columns:repeat(auto-fill,minmax(88px,1fr));}.score .scorenum{font-size:42px;}.foot a{display:block;max-width:340px;margin:0 auto;}.stats{gap:8px;}.stat{padding:9px 13px;}}
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
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="preconnect" href="https://image.tmdb.org">
<link href="https://fonts.googleapis.com/css2?family=DM+Serif+Display&family=Limelight&display=swap" rel="stylesheet">
<link rel="icon" type="image/png" href="/favicon.png">
<style>${BASE_CSS}</style>
</head><body>
<header class="hdr"><div class="hdr-in"><a class="wordmark" href="/">cini</a><a class="getcini" href="${APP_STORE}">Get Cini</a></div></header>
<main class="wrap">
${bodyHtml}
</main></body></html>`;
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
