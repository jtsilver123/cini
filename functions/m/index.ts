// SSR for /m/?id=<tmdb_id> — a title page with Cini's community score, who
// ranked it, and notes. Indexable (no PII; this is the SEO surface). og:image
// is the TMDB backdrop so the link unfurls with real art. Overrides the static
// m/index.html on Cloudflare; static stays the fallback.
import { rpc, esc, tmdb, safeHttps, scoreColor, shell, notFoundPage, OG_FALLBACK } from "../_lib";

interface Title {
  tmdb_id: number; media_kind: string; title: string; release_year: number | null;
  poster_path: string | null; backdrop_path: string | null; overview: string | null;
  genres: string[] | null; runtime_minutes: number | null; director: string | null;
  community: { avg: number; count: number } | null;
  histogram: { floor: number; n: number }[];
}
interface Extras {
  rankers: { username: string; display_name: string; avatar_url: string | null; score: number }[];
  notes: { username: string; display_name: string; avatar_url: string | null; body: string; spoilers: boolean }[];
}

export const onRequestGet: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const id = parseInt((url.searchParams.get("id") || "").replace(/[^0-9-]/g, ""), 10);
  if (Number.isNaN(id)) return notFoundPage("This title isn’t on Cini yet.");

  const [t, extra] = await Promise.all([
    rpc<Title>("public_title", { p_movie_id: id }),
    rpc<Extras>("public_title_extras", { p_movie_id: id }),
  ]);
  if (!t) return notFoundPage("This title isn’t on Cini yet.");

  const yr = t.release_year ? ` (${t.release_year})` : "";
  const kind = t.media_kind === "tv" ? "TV" : "Film";
  const backdrop = tmdb(t.backdrop_path, "w780") || tmdb(t.poster_path, "w500");
  const ogImage = backdrop || OG_FALLBACK;
  const poster = tmdb(t.poster_path, "w342");

  const scoreBlock = t.community
    ? `<div class="score"><div class="scorenum" style="color:${scoreColor(Number(t.community.avg))}">${Number(t.community.avg).toFixed(1)}</div>
       <div><div>Cini community score</div><div class="sub">${t.community.count} ${t.community.count === 1 ? "ranking" : "rankings"}</div></div></div>`
    : `<div class="sub" style="margin-top:18px;">Not ranked on Cini yet — be the first.</div>`;

  const genres = Array.isArray(t.genres) && t.genres.length
    ? `<div class="genres">${t.genres.slice(0, 5).map((g) => `<span class="chip">${esc(g)}</span>`).join("")}</div>` : "";

  const rankers = extra?.rankers?.length
    ? `<div class="seg" style="margin-top:26px;">WHO RANKED IT</div><div style="display:flex;gap:14px;overflow-x:auto;padding-bottom:6px;">` +
      extra.rankers.slice(0, 20).map((p) => {
        const av = safeHttps(p.avatar_url);
        const ini = (p.display_name || p.username || "•").trim()[0].toUpperCase();
        const face = av ? `<img src="${esc(av)}" alt="" style="width:48px;height:48px;border-radius:50%;object-fit:cover;">`
          : `<div style="width:48px;height:48px;border-radius:50%;background:var(--surface2);display:flex;align-items:center;justify-content:center;font-weight:700;color:var(--marquee);">${esc(ini)}</div>`;
        return `<a href="/u/?u=${encodeURIComponent(p.username)}" style="flex:none;width:56px;text-align:center;">${face}
          <div style="font-weight:800;font-size:13px;margin-top:5px;color:${scoreColor(Number(p.score))}">${Number(p.score).toFixed(1)}</div>
          <div style="font-size:10.5px;color:var(--gray);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${esc(p.display_name ? p.display_name.split(" ")[0] : p.username)}</div></a>`;
      }).join("") + `</div>` : "";

  const notes = extra?.notes?.length
    ? `<div class="seg" style="margin-top:26px;">NOTES</div>` +
      extra.notes.slice(0, 12).map((n) => {
        const av = safeHttps(n.avatar_url);
        const ini = (n.display_name || n.username || "•").trim()[0].toUpperCase();
        const face = av ? `<img src="${esc(av)}" alt="" style="width:26px;height:26px;border-radius:50%;object-fit:cover;">`
          : `<div style="width:26px;height:26px;border-radius:50%;background:var(--surface2);display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:700;color:var(--marquee);">${esc(ini)}</div>`;
        return `<div style="border:1px solid var(--hair);border-radius:14px;padding:13px 15px;margin-bottom:10px;">
          <a href="/u/?u=${encodeURIComponent(n.username)}" style="display:flex;align-items:center;gap:8px;margin-bottom:7px;">${face}<span style="font-weight:700;font-size:13px;">${esc(n.display_name || "@" + n.username)}</span></a>
          <div style="font-size:14px;line-height:1.5;opacity:.92;${n.spoilers ? "filter:blur(6px);" : ""}">${esc(n.body)}</div></div>`;
      }).join("") : "";

  const body = `
    ${backdrop ? `<div style="margin:8px -16px 0;height:200px;background:url('${esc(backdrop)}') center/cover;border-radius:14px;position:relative;"><div style="position:absolute;inset:0;background:linear-gradient(180deg,transparent,var(--bg));border-radius:14px;"></div></div>` : ""}
    <div class="head" style="margin-top:${backdrop ? "-40px" : "6px"};position:relative;">
      ${poster ? `<div class="poster" style="width:120px;flex:none;background-image:url('${esc(poster)}');"></div>` : ""}
      <div><div class="title">${esc(t.title)}</div>
      <div class="sub">${[t.release_year, t.director, t.runtime_minutes ? `${t.runtime_minutes} min` : null, kind].filter(Boolean).map(esc).join(" · ")}</div></div>
    </div>
    ${scoreBlock}
    ${genres}
    ${t.overview ? `<div class="overview">${esc(t.overview)}</div>` : ""}
    ${rankers}
    ${notes}
    <div class="divider"></div>
    <div class="foot"><a href="cini://movie?id=${id}">Rank it in Cini</a>
    <p>Cini — everything you watch, ranked. No star ratings, just taste.</p></div>`;

  return shell({
    title: `${t.title}${yr} — ranked on Cini`,
    description: t.community
      ? `${t.title}${yr} scores ${Number(t.community.avg).toFixed(1)} from ${t.community.count} Cini ${t.community.count === 1 ? "ranking" : "rankings"} — ranked by taste, not stars.`
      : `${t.title}${yr} on Cini — rank it by taste, no star ratings.`,
    canonical: `https://trycini.com/m/?id=${id}`,
    ogImage,
    jsonLd: {
      "@context": "https://schema.org",
      "@type": t.media_kind === "tv" ? "TVSeries" : "Movie",
      name: t.title,
      ...(t.release_year ? { datePublished: String(t.release_year) } : {}),
      ...(t.community ? { aggregateRating: { "@type": "AggregateRating", ratingValue: t.community.avg, ratingCount: t.community.count, bestRating: 10, worstRating: 0 } } : {}),
    },
    bodyHtml: body,
  });
};
