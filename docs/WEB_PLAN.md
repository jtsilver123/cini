# WEB_PLAN.md — a read-only public web layer for Cini

Status: **proposal / not yet built.** This is the plan for giving Cini a
Letterboxd-style public web presence WITHOUT rebuilding the app for the browser.
Scope is deliberately narrow: **read-only public pages** that (a) make every
shared link land on real content and (b) earn organic search traffic. Logging,
head-to-head ranking, and the swipe deck stay app-only.

---

## 1. Goal & non-goals

**Goal.** Two growth levers Letterboxd gets from the web that a pure iOS app
can't:
1. **Shareable links that land somewhere.** Today a shared ranking/list points at
   the App Store (`AppLinks.swift`: only `invite` `/i/` and `listLink` `/l/`
   exist, and `/l/` just bounces to the app). A friend without Cini sees nothing.
   Public pages turn every share into "see the content → install" funnel.
2. **Discovery / SEO.** We already ship programmatic `/reviews/<slug>/` pages
   (static, SEO-rich). Extend that into "Cini has a page for every member,
   every public list, and every title," which is what pulls Google traffic.

**Non-goals (defer until there's pull).**
- No interactive web app: no logging, no ranking comparisons, no swipe deck.
  The ranking engine is pure Swift (`RankingEngine`); a web port or an API
  fronting it is a large, separate effort.
- No web auth / account management beyond what `/admin` already does.
- No write paths of any kind from the web.

---

## 2. The hard constraint we discovered

**Anon (logged-out) reads return NOTHING today.** Every selectable table's RLS is
`for select to authenticated`; the only function granted to `anon` in the entire
migration set is `phone_available`. `can_view`, `movie_page_stats`,
`movie_friend_scores`, etc. all explicitly `revoke ... from anon`.

So a public web page **cannot** just point the publishable key at PostgREST —
it needs **net-new `anon`-callable `SECURITY DEFINER` RPCs**, each one scoped to
return only `not is_private` content. This is the backbone of the whole plan and
the main backend work.

Good news: the privacy model is already the right shape for this.
- `profiles.is_private boolean default false` (also on `notes`, `custom_lists`).
- `can_view(owner)` = "is me OR `not is_private` OR I follow them."
- The **public** slice we expose to anon is exactly the `not is_private` half of
  `can_view`, minus the follow branch (anon has no identity) — a clean subset.

---

## 3. Architecture decision — rendering

Three options; recommendation is a **hybrid**.

| | How | SEO | Social unfurl (OG cards) | Freshness | Infra cost |
|---|---|---|---|---|---|
| A. Client-rendered shell | static HTML + supabase-js calls anon RPCs at runtime (the `/admin` pattern) | weak (JS-rendered) | **none** (crawlers see an empty shell) | live | **none** (existing GitHub Pages) |
| B. Static pre-render | a build script writes one static HTML per entity (the `/reviews/` pattern) | best | perfect | stale; can't enumerate every user/list | none, but doesn't scale to per-user |
| C. Edge SSR | a function renders HTML+meta per request from the DB | best | perfect | live | needs an edge runtime (not GitHub Pages) |

**Recommendation:**
- **Title pages** (`/m/<slug>`) → **B, static pre-render**, extending the
  existing `build_review_pages.py`. Titles are a bounded, high-SEO-value set and
  we already generate review pages for them. Merge the two.
- **Profile + list pages** (`/u/<username>`, `/l/<id>`) → **C, edge SSR**, because
  they must (a) unfurl as rich OG cards in iMessage/social — the actual viral
  loop — and (b) stay fresh, and (c) can't be statically enumerated without
  leaking the directory. GitHub Pages can't run server code, so these routes move
  to an edge runtime.

**Edge runtime choice:** Cloudflare Pages/Workers (the Cloudflare MCP is already
available to this project). Keep the static marketing site + `/reviews/` + `/m/`
exactly as-is; put `/u/*` and `/l/*` behind a Worker that server-renders meta +
initial HTML from the anon RPCs, then optionally hydrates. Net: the apex domain's
DNS/routing is the only infra change; everything static stays static.

> If we'd rather avoid the Cloudflare move for v1, Phase 1 can ship **option A**
> (client-rendered on the current GitHub Pages) — links work for humans
> immediately; the only thing missing is rich OG unfurl and crawl-friendliness,
> which Phase 2's edge SSR then adds. This is the lowest-risk way to get value
> this week.

---

## 4. Backend — new anon-callable RPCs (the core work)

All `SECURITY DEFINER`, `set search_path = public`, `revoke from public` then
`grant execute to anon, authenticated`. Each returns ONLY `not is_private` data
and never anything block- or follow-gated (anon has no `auth.uid()`).

1. **`public_profile(p_username text)`** → one row:
   `id, username, display_name, avatar_url, school, grad_year, member_since,
   streak_weeks, ranked_count, list_count` — and crucially returns nothing (or a
   `private` sentinel) when `is_private`. Counts computed inside the function.
2. **`public_rankings(p_username text, p_limit int default 100)`** → the member's
   ranked titles joined to `movies`: `movie_id, media_kind, title, poster_path,
   release_year, bucket, position, score`. Gated on `not is_private`.
3. **`public_list(p_list_id uuid)`** → list header + items joined to `movies`,
   only when the list's own `is_private` is false AND the owner is `not is_private`.
4. **`public_title(p_movie_id int)`** → anon-safe movie page data: the movies row
   + `movie_community_scores` aggregate (`avg_score`, `rating_count`) +
   `movie_score_histogram`. **NOT** `movie_friend_scores` (that's `auth.uid()`-
   gated and meaningless for anon).
5. **`public_title_by_slug(p_slug text)`** → resolves a `<title>-<year>` slug to a
   tmdb_id. Requires a **slug column or mapping** (see §6) since slugs aren't
   stored today.

Mirror each into `supabase/migrations/` and run `contract_check.py` (add them to
its RPC list). These are pure reads of already-public data, so they don't widen
the security surface beyond "what a logged-in user could already see on a public
profile."

**Rate-limiting / abuse:** anon endpoints are scrapeable. Acceptable for v1
(the data is public-by-choice and low-sensitivity), but put Cloudflare in front
for basic rate limiting, and keep the RPCs `STABLE` + cheap.

---

## 5. Privacy & safety (must honor the existing model exactly)

- **`is_private` is the gate, default public.** Every RPC returns the private
  user's pages as 404/"this profile is private," never their content.
- **Opt-in to indexing.** Even for public profiles, default to
  `<meta name="robots" content="noindex">` on member/list pages until we add an
  explicit "let my profile show up in search" toggle, OR decide public = indexable
  as a product call. Title pages (`/m/`) are always indexable (no PII).
- **Notes:** only `not is_private` notes, matching `notes_select`.
- **Blocks:** irrelevant for anon (no identity), but a blocked *viewer* who is
  logged into the app still goes through `can_view` in-app — unchanged.
- **Leaked-password / auth:** N/A — no auth on these pages.

---

## 6. URLs, slugs & deep links

**New URL scheme (all under trycini.com):**
- `/u/<username>` — public profile + their ranked list + lists.
- `/l/<uuid>` — **upgrade** the existing list landing from "bounce to app" to a
  real rendered list (keep the app-open button).
- `/m/<slug>` — title page; `<slug>` = `slugify(title, year)` (reuse
  `build_review_pages.py:slugify`). Fold `/reviews/<slug>/` into `/m/` (301 the
  old paths) so there's one canonical title URL.

**Slug↔tmdb_id:** slugs aren't persisted today and review slugs are derived at
generation time. Add a `slug text unique` column to `movies` (or a small
`movie_slugs` table) populated by `cache_movie`, so `public_title_by_slug` and
dynamic title links resolve. Handle collisions with the existing de-dupe logic.

**App share links** (`AppLinks.swift`) — add:
- `profileLink(username)` → `https://trycini.com/u/<username>`
- `titleLink(movie)` → `https://trycini.com/m/<slug>`
- repoint the ranking/list share sheets (`ShareCards`, `YourListsView`,
  `ProfileView`) at these instead of the App Store URL.

**Universal Links** (`.well-known/apple-app-site-association`) — add `/u/*` and
`/m/*` to the `paths` array (currently only `/i/*`, `/l/*`) so tapping a shared
link on a device with the app opens the app, and the web page is the fallback.
Add matching `handleURL` routes in `CiniApp.swift` (`/u` → open profile,
`/m` → open movie) — `openList` already shows the pattern.

---

## 7. Frontend

Reuse the existing look so the web feels like Cini, not a bolt-on:
- Lift the type/color/wordmark from `site.css` (the `rv-*` classes) and the
  prototype's components (poster grid, `ScoreBadge` styling, avatar).
- Title pages: extend the `build_review_pages.py` templates (they already emit
  JSON-LD `Movie`/`TVSeries`, OG/Twitter tags, canonical, where-to-watch chips,
  cast). Add the Cini community score + histogram from `public_title`.
- Profile/list pages (edge SSR): server-render `<head>` (title, OG image, JSON-LD
  `ProfilePage`/`ItemList`) + the ranked list, then a small JS enhancement for
  "load more." OG image = a generated card (we already render share cards via
  `ImageRenderer` in-app; do the web equivalent with a small `@vercel/og`-style
  function or a static fallback poster collage).

---

## 8. SEO

- One canonical title URL (`/m/<slug>`); 301 `/reviews/` → `/m/`.
- `sitemap.xml`: keep titles (already generated); add public profiles + public
  lists from a nightly job that lists `not is_private` owners.
- JSON-LD per page type; OG cards on every shareable URL (the unfurl is the
  growth mechanic).
- `robots.txt`: allow titles; gate member/list indexing on the §5 decision.

---

## 9. Phasing

**Phase 1 — links that work (1 slice, ~days).**
Anon RPCs `public_profile` + `public_rankings` + upgrade `public_list`.
Client-rendered `/u/` and richer `/l/` on the **existing GitHub Pages** (option A,
the `/admin` supabase-js pattern). Add `profileLink`/`titleLink` to `AppLinks` and
repoint the share sheets. Result: every shared profile/list opens to real content
in any browser, with an install CTA. (No rich unfurl yet.)

**Phase 2 — discovery + unfurl (the growth flywheel).**
Move `/u/*`,`/l/*` to Cloudflare edge SSR for OG cards + crawlability. Merge
`/reviews/` into `/m/<slug>` with `public_title`; add the slug column. Sitemaps +
JSON-LD + OG images. This is where organic traffic and viral shares compound.

**Phase 3 — (optional, later) interactive web.**
Only if web traffic justifies it: an API over the ranking engine and authenticated
web logging. Big lift; explicitly out of scope now.

---

## 10. Open decisions for Jake

1. **Public = search-indexable?** Or require an explicit opt-in toggle first?
   (Affects whether member pages get `noindex` in Phase 1.)
2. **Cloudflare move** for edge SSR in Phase 2 — OK to migrate the apex routing,
   or keep everything on GitHub Pages and accept weaker unfurl?
3. **Ship Phase 1 client-rendered now**, or wait and do it once with edge SSR?

None of this is built yet — it's the map. Say which phase to start and I'll
implement it behind the existing site, gated on `contract_check.py` + CI as usual.
