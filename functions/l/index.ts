// SSR for /l/?id=<uuid> — a public custom list (header + owner + items), so a
// shared list link unfurls with art and renders without JS. og:image is the
// first item's poster. noindex (someone's curated list, not a search target).
import { rpc, esc, tmdb, safeHttps, shell, notFoundPage, OG_FALLBACK } from "../_lib";

interface ListData {
  id: string; name: string; media_kind: string;
  owner: { username: string; display_name: string; avatar_url: string | null };
  items: { movie_id: number; title: string; poster_path: string | null; release_year: number | null }[];
}

export const onRequestGet: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const id = (url.searchParams.get("id") || "").replace(/[^a-f0-9-]/gi, "").slice(0, 40);
  if (!id) return notFoundPage("This list isn’t available.");

  const list = await rpc<ListData>("public_list", { p_list_id: id });
  if (!list) return notFoundPage("This list isn’t available — it may be private.");

  const items = Array.isArray(list.items) ? list.items : [];
  const ogImage = tmdb(items[0]?.poster_path, "w500") || OG_FALLBACK;
  const owner = list.owner || ({} as ListData["owner"]);
  const ownerName = owner.display_name || `@${owner.username || "someone"}`;
  const avatar = safeHttps(owner.avatar_url);

  const grid = items.map((m) => {
    const p = tmdb(m.poster_path, "w342");
    return `<a class="card" href="/m/?id=${m.movie_id}">
      <div class="poster" style="background-image:${p ? `url('${esc(p)}')` : "none"}"></div>
      <div class="ptitle">${esc(m.title || "")}</div>${m.release_year ? `<div class="pyear">${esc(m.release_year)}</div>` : ""}
    </a>`;
  }).join("");

  const body = `
    <div class="title">${esc(list.name || "Untitled list")}</div>
    <div class="sub" style="display:flex;align-items:center;gap:8px;margin-top:8px;">
      ${avatar ? `<img src="${esc(avatar)}" alt="" style="width:26px;height:26px;border-radius:50%;object-fit:cover;">` : ""}
      <span>by ${esc(ownerName)}</span></div>
    <div class="sub">${items.length} ${items.length === 1 ? "title" : "titles"}</div>
    <div class="divider"></div>
    ${items.length ? `<div class="grid">${grid}</div>` : `<div class="msg">This list is empty.</div>`}
    <div class="foot"><a href="cini://list?id=${esc(id)}">Open this list in Cini</a>
    <p>Cini — everything you watch, ranked. No star ratings, just taste.</p></div>`;

  return shell({
    title: `${list.name || "A list"} · Cini`,
    description: `${ownerName}’s list on Cini — ${items.length} ${items.length === 1 ? "title" : "titles"}, ranked by taste.`,
    canonical: `https://trycini.com/l/?id=${esc(id)}`,
    ogImage,
    noindex: true,
    bodyHtml: body,
  });
};
