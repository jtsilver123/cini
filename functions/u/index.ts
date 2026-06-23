// SSR for /u/?u=<username> — a public member's profile + rankings + lists, with
// real per-page meta so the link unfurls and (if we choose to index later) is
// crawlable. Overrides the static u/index.html when running on Cloudflare; the
// static page remains the fallback off-Cloudflare. Member pages stay noindex
// until there's an explicit "show me in search" opt-in.
import { rpc, esc, tmdb, safeHttps, scoreColor, shell, notFoundPage, OG_FALLBACK } from "../_lib";

interface Profile {
  username: string; display_name: string; avatar_url: string | null; bio: string | null;
  streak_weeks: number; ranked_count: number; list_count: number;
  instagram: string | null; tiktok: string | null; x: string | null; letterboxd: string | null;
}
interface Rank { movie_id: number; title: string; poster_path: string | null; release_year: number | null; score: number; }
interface List { id: string; name: string; media_kind: string; count: number; }

export const onRequestGet: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const username = (url.searchParams.get("u") || "").toLowerCase().replace(/[^a-z0-9_.]/g, "").slice(0, 30);
  if (username.length < 3) return notFoundPage("This profile isn’t available.");

  const [prof, ranks, lists] = await Promise.all([
    rpc<Profile>("public_profile", { p_username: username }),
    rpc<Rank[]>("public_rankings", { p_username: username, p_limit: 250 }),
    rpc<List[]>("public_profile_lists", { p_username: username }),
  ]);
  if (!prof) return notFoundPage("This profile isn’t available — it may be private.");

  const name = prof.display_name || `@${prof.username}`;
  const ogImage = safeHttps(prof.avatar_url) || OG_FALLBACK;
  const rankList = Array.isArray(ranks) ? ranks : [];
  const listList = Array.isArray(lists) ? lists : [];

  const avatar = safeHttps(prof.avatar_url);
  const initials = (name.trim().split(/\s+/).filter(Boolean).slice(0, 2).map((w) => w[0]).join("") || "•").toUpperCase();

  const socials: string[] = [];
  const h = (v: string | null) => String(v || "").replace(/[^A-Za-z0-9_.]/g, "");
  if (prof.instagram) socials.push(`<a href="https://instagram.com/${h(prof.instagram)}" rel="noopener nofollow">Instagram</a>`);
  if (prof.tiktok) socials.push(`<a href="https://tiktok.com/@${h(prof.tiktok)}" rel="noopener nofollow">TikTok</a>`);
  if (prof.x) socials.push(`<a href="https://x.com/${h(prof.x)}" rel="noopener nofollow">X</a>`);
  if (prof.letterboxd) socials.push(`<a href="https://letterboxd.com/${h(prof.letterboxd)}" rel="noopener nofollow">Letterboxd</a>`);

  const grid = rankList.map((m) => {
    const p = tmdb(m.poster_path, "w342");
    const badge = m.score != null ? `<div class="badge" style="color:${scoreColor(Number(m.score))}">${Number(m.score).toFixed(1)}</div>` : "";
    return `<a class="card" href="/m/?id=${m.movie_id}">
      <div class="poster" style="background-image:${p ? `url('${esc(p)}')` : "none"}">${badge}</div>
      <div class="ptitle">${esc(m.title || "")}</div>${m.release_year ? `<div class="pyear">${esc(m.release_year)}</div>` : ""}
    </a>`;
  }).join("");

  const listsHtml = listList.length
    ? `<div class="divider"></div><div class="seg">LISTS</div><div class="lists">` +
      listList.map((L) => `<a class="listchip" href="/l/?id=${esc(L.id)}"><span class="lname">${esc(L.name || "Untitled")}</span><span class="lcount">${L.count ?? 0}</span></a>`).join("") +
      `</div>`
    : "";

  const body = `
    <div class="head">
      ${avatar ? `<img class="avatar" src="${esc(avatar)}" alt="">` : `<div class="avatar">${esc(initials)}</div>`}
      <div><div class="name">${esc(name)}</div><div class="sub">@${esc(prof.username)}</div></div>
    </div>
    ${prof.bio ? `<div class="bio">${esc(prof.bio)}</div>` : ""}
    <div class="stats">
      <div class="stat"><b>${prof.ranked_count ?? 0}</b><span>ranked</span></div>
      <div class="stat"><b>${prof.list_count ?? 0}</b><span>lists</span></div>
      ${prof.streak_weeks ? `<div class="stat"><b>🔥 ${prof.streak_weeks}</b><span>wk streak</span></div>` : ""}
    </div>
    ${socials.length ? `<div class="sub" style="display:flex;gap:14px;margin-top:12px;">${socials.join("")}</div>` : ""}
    ${listsHtml}
    <div class="divider"></div>
    <div class="seg">${rankList.length ? "RANKED · HIGHEST FIRST" : "RANKINGS"}</div>
    ${rankList.length ? `<div class="grid">${grid}</div>` : `<div class="msg">No public rankings yet.</div>`}
    <div class="foot"><a href="https://apps.apple.com/us/app/cini-rank-every-film/id6778975898">See ${esc(name.split(" ")[0])}’s taste in Cini</a>
    <p>Cini — everything you watch, ranked. No star ratings, just taste.</p></div>`;

  return shell({
    title: `${name} on Cini`,
    description: `${name} has ranked ${prof.ranked_count ?? 0} movies & shows on Cini — no star ratings, just taste, perfectly ordered.`,
    canonical: `https://trycini.com/u/?u=${encodeURIComponent(prof.username)}`,
    ogImage,
    ogType: "profile",
    noindex: true,
    jsonLd: {
      "@context": "https://schema.org",
      "@type": "ProfilePage",
      mainEntity: { "@type": "Person", name, alternateName: `@${prof.username}` },
    },
    bodyHtml: body,
  });
};
