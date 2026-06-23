# Cloudflare deploy — rich link previews + crawlable public pages

This is the runbook for the edge-SSR phase (see `docs/WEB_PLAN.md` §3). It moves
trycini.com onto **Cloudflare Pages** so the public web pages can be
**server-rendered**: shared `/u`, `/m`, `/l` links unfurl as rich cards (real
title, description, artwork) in iMessage / social, and search engines can read
the pages. The static site stays the same; Cloudflare just runs a little code
per request for those routes.

**Status: code committed, NOT deployed.** The setup steps below need your
Cloudflare account and DNS — they couldn't be done from the build session
(no authorized Cloudflare access). Until then, nothing changes: GitHub Pages
keeps serving the site and the client-rendered pages keep working.

---

## What's in the repo

- **`functions/`** — Cloudflare Pages Functions (TypeScript), auto-detected by
  Cloudflare Pages:
  - `functions/u/index.ts` → SSR for `/u/?u=<username>` (profile)
  - `functions/m/index.ts` → SSR for `/m/?id=<tmdb_id>` (title; indexable)
  - `functions/l/index.ts` → SSR for `/l/?id=<uuid>` (list)
  - `functions/_lib.ts` — shared rendering + the `public_*` RPC fetches.
  They mount at the **same query-param paths the app already links to**, and
  Functions take precedence over the static `u/`,`m/`,`l/` files — so once this
  is live, **every existing shared link gets the rich treatment with no app
  update**. The static pages remain the fallback anywhere Functions don't run.
- **`scripts/build_site.sh`** — assembles `_site/` (the static half), so
  Cloudflare serves only web files, never the whole repo.

The preview image (`og:image`) in this v1 uses **real artwork** — the TMDB
backdrop for titles, the avatar for profiles, the first poster for lists. That
already unfurls well. A fancier *generated* card (poster collage + score + name)
is a follow-up (see "Next" below).

---

## One-time setup (you do this)

1. **Create the Pages project.** Cloudflare dashboard → Workers & Pages →
   Create → Pages → **Connect to Git** → pick `jtsilver123/cini`, branch
   `claude/ecstatic-cori-k7s2n0` (or main, once merged).
2. **Build settings:**
   - Framework preset: **None**
   - Build command: **`bash scripts/build_site.sh`**
   - Build output directory: **`_site`**
   - (Functions are picked up from `/functions` automatically — nothing to set.)
3. **Deploy.** The first build publishes to a `*.pages.dev` URL. Open
   `https://<project>.pages.dev/u/?u=jtsilver123` and
   `/m/?id=13` to confirm SSR works (view source — the title/description/og tags
   should be filled in, not generic).
4. **Custom domain + DNS.** In the Pages project → Custom domains → add
   `trycini.com` (and `www`). Cloudflare will walk you through pointing the
   domain's nameservers/records at Cloudflare. This is the cutover from GitHub
   Pages — the apex can only serve from one place, so once DNS flips, Cloudflare
   serves everything (static + the SSR routes).
   - The `CNAME` file in the repo is for GitHub Pages and is harmless on
     Cloudflare.
5. **Verify after DNS propagates:** paste a `/u/?u=…` or `/m/?id=…` link into
   iMessage / a tweet and confirm it unfurls with a card.

No secrets are needed: the anon key in `functions/_lib.ts` is the publishable
key (same one the app ships), and every `public_*` RPC is non-private-scoped.

## Rollback
If anything's wrong, remove the custom domain from the Pages project and point
DNS back at GitHub Pages — the static site (with client-rendered pages) is
unchanged and still complete.

## Next (follow-ups, not in this commit)
- **Generated preview cards** (`/og/...` via `workers-og`): a branded poster
  collage + score image instead of plain artwork. Needs an image lib that can't
  be tested without a Cloudflare runtime, so it's staged for after the first
  deploy when we can iterate against a live preview.
- **Pretty paths** (`/u/jake`, `/m/the-dark-knight-2008`): add path-param
  Functions + repoint `AppLinks` once the query-param SSR is proven.
- **SSR the charts page** for full search indexing (it's client-rendered today).
