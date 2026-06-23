// /m/?id=<tmdb_id> is the app's title share link. It now 301-redirects to the
// canonical, keyword-rich /title/<slug> (single source of truth, server-rendered
// with the live community score). Keeping this endpoint means every link the app
// has already shared consolidates onto the canonical page with no app update.
import { rpc, notFoundPage } from "../_lib";

interface TitleStub { slug: string | null }

export const onRequestGet: PagesFunction = async (context) => {
  const url = new URL(context.request.url);
  const id = parseInt((url.searchParams.get("id") || "").replace(/[^0-9-]/g, ""), 10);
  if (Number.isNaN(id)) return notFoundPage("This title isn’t on Cini yet.");

  const t = await rpc<TitleStub>("public_title", { p_movie_id: id });
  if (!t || !t.slug) return notFoundPage("This title isn’t on Cini yet.");

  return new Response(null, {
    status: 301,
    headers: {
      location: `/title/${t.slug}`,
      "cache-control": "public, max-age=3600",
    },
  });
};
