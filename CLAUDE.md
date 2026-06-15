# CLAUDE.md — Cini agent operating manual

This is the first file to read when working on Cini. It tells an AI agent
what Cini is, the rules that must never be broken, where everything lives,
and how to ship a change safely. Pair it with:

- **`docs/DESIGN.md`** — the design system (brand, tokens, components, UI laws).
- **`docs/ARCHITECTURE.md`** — the ranking engine, persistence, RLS, taste match.
- **`docs/HANDOFF.md`** — running status log + build/credentials history.
- **`docs/EDGE_CASES.md`**, **`docs/APP_STORE_*.md`** — QA + submission.

---

## 1. What Cini is

Cini is **"Beli for movies & TV"** — an iOS app where people rank everything
they watch through quick head-to-head comparisons, follow friends, and get
recommendations. Native **SwiftUI** front end, **Supabase** (Postgres +
Auth + Storage + Edge Functions) back end, plus a pure-Swift **RankingEngine**
package for the comparison math. There is also a **web prototype** (HTML/JS)
that mirrors the app for demos.

The founder (Jake) is **non-technical** — explain changes in plain language,
and never assume he'll read code to understand what shipped.

---

## 2. Golden rules (do not break these)

These are standing user directives. They override convenience every time.

1. **Builds are on request only.** Never trigger the TestFlight workflow
   (`testflight.yml`) unless the user explicitly asks for "a build." Commit
   and push freely — CI validates every push — but Apple caps uploads per
   day, so builds are batched and shipped only when asked. See §6.
2. **Movies and TV are the only two content types**, equal everywhere.
   Documentaries/anime/etc. are *genres* (searchable, filterable), never
   top-level categories. Any new surface must treat Movies and TV identically.
3. **Identical actions live in identical places.** Reuse shared components
   so placements physically can't drift (see DESIGN.md §UI laws). The `(+)` /
   bookmark quick actions are scrimmed circles bottom-right on artwork via
   `ArtworkQuickActions`; scores are a trailing `ScoreBadge`; etc.
4. **Mirror meaningful features in the web prototype** (`prototype/index.html`,
   live at trycini.com/prototype/). If a change alters app
   behavior or UX a user would notice, reflect it in the prototype too.
5. **The repo is PUBLIC.** Never commit secrets. The TMDB key in
   `Cini/Resources/Secrets.xcconfig` is a *client* key and is intentionally
   committed; the App Review demo account
   (`appreview@cini-demo.com` / `CiniReview2026!`) is intentionally public.
   Anything else sensitive belongs in GitHub Actions secrets or Supabase Vault.
6. **Support email is `jtsilver123@gmail.com` everywhere.** Nothing
   "bettercampus" ever appears in the app, site, or store listing.
7. **Leaked-password protection is N/A** (free Supabase plan) — never raise it
   as a finding.
8. **Keep the harness/model identity out of artifacts.** Never put an AI model
   name/identifier in commit messages, PR titles/bodies, code comments, or any
   pushed file. Chat replies only.

---

## 3. Repository map

```
project.yml              XcodeGen project definition — the SINGLE source of
                         truth for the Xcode project. There is NO committed
                         .xcodeproj; every pipeline runs `xcodegen generate`.
                         `sources: - Cini` means ANY file under Cini/ is
                         auto-included — no manual project edits to add a file.

Cini/                    The iOS app (SwiftUI).
  App/                   Entry point, RootTabView, TabRouter, Siri intents.
  DesignSystem/          Theme.swift (tokens) + shared components
                         (ScoreBadge, AvatarView, PosterView, PillButton,
                         ArtworkQuickActions, CropImagePicker, RankTicket…).
  Features/              One folder per feature area (Feed, Profile, Search,
                         MovieDetail, LogFlow, Lists, Leaderboard, Onboarding,
                         Chat, Notifications…). UI lives here.
  Services/              SupabaseService (every network call), RankingStore
                         (the shared cache/store), TMDBService, PushManager,
                         caches, ToastCenter.
  Models/                Codable models (Movie, Profile, WatchlistItem…).
  Resources/             Secrets.xcconfig, Info.plist, entitlements, fonts.

RankingEngine/           Pure-Swift package: the comparison state machine
                         (Sentiment, InsertionSession, RankingList,
                         ScoreCalculator). UI- and network-free. Has its own
                         unit tests (run in CI).

CiniTests/               App-level unit tests.

supabase/
  migrations/            SQL migrations (numbered). Applied to prod AND
                         mirrored here — the repo must match production.
  functions/             Edge Functions (Deno/TypeScript). Deployed AND
                         mirrored here.
  templates/             Auth email templates.

scripts/contract_check.py  Live contract harness — runs every app query/RPC
                           (and a Storage smoke test) against PRODUCTION as the
                           demo user. Run before pushing backend/query changes.

prototype/index.html     Self-contained web mockup of the app (mirror rule #4).
index.html, *.html, site.css   Marketing site + legal pages (GitHub Pages).

.github/workflows/
  ci.yml          Validates every push: engine tests + app build/tests on a
                  simulator + the live contract check. THIS is the gate.
  testflight.yml  Builds + uploads to TestFlight. Manual / on-request only.
  pages.yml       Publishes the marketing site + prototype on push.

docs/             Architecture, design, handoff, edge cases, store docs.
```

---

## 4. How to work (the loop)

1. **Branch.** Develop on the feature branch the task names (currently
   `claude/ecstatic-cori-k7s2n0`). Create it locally if missing. Never push to
   another branch without explicit permission.
2. **Make the change.** Match surrounding style. Reuse shared components and
   `Theme` tokens — don't hand-roll colors/placements (DESIGN.md).
3. **If it touches the backend or any query/RPC**, run
   `python3 scripts/contract_check.py` — it must print **"All contracts hold."**
   (`--write` also exercises mutating RPCs as the demo account.)
4. **Mirror to the prototype** if the change is user-visible (rule #4).
5. **Commit** with a clear, plain-language message (no model identifiers).
6. **Push** with `git push -u origin <branch>` (retry on transient network
   errors with backoff).
7. **Gate on CI.** Find the `ci.yml` run for your head SHA and confirm it goes
   **green** before declaring done. If red, read the failing job and fix.
8. **Only build when asked** (§6).

Reporting: lead with the outcome in plain language. The founder reads the
final message, not the tool log.

---

## 5. Backend changes (Supabase project `npumchnkbcajyuhurgez`)

- **Schema changes** are SQL migrations: write the migration, apply it to prod
  (via the Supabase MCP `apply_migration`), AND save the file in
  `supabase/migrations/` so the repo matches prod. Numbered sequentially.
- **Edge Functions**: deploy to prod AND mirror the source in
  `supabase/functions/<name>/index.ts`.
- **After any schema/query change, run `contract_check.py`** — it executes the
  real queries against prod and catches drift that static review can't (renamed
  columns, ambiguous embeds, dropped functions, revoked grants, RLS gaps).
- **Storage RLS gotcha:** an upload does `INSERT … RETURNING`, which needs a
  **SELECT** policy on `storage.objects` as well as INSERT. Without SELECT,
  the write fails as HTTP 400 (Storage wraps RLS denials as 400, not 403).
  Buckets: `avatars` (public read), `imports` (private).
- **RPCs** are mostly `SECURITY DEFINER` with `can_view(owner)` gating; the
  SECURITY DEFINER advisor warnings are intentional. `rank_insert` is the
  authoritative ranking write (locks, shifts, rescores, emits feed events).
- **pg_cron** runs nightly jobs (taste-match refresh, predicted-score cache,
  availability alerts). Some were scheduled via direct SQL — check
  `cron.job` in prod, not just the migrations, before claiming one is missing.

---

## 6. Builds (TestFlight) — ON REQUEST ONLY

When (and only when) the user asks for a build:

1. Ensure the **`ci.yml` run for the head commit is green** first.
2. Trigger `testflight.yml` via the GitHub Actions MCP `actions_run_trigger`
   (run_workflow): workflow `testflight.yml`, ref = the working branch,
   inputs `{"issuer_id": "a3b57c9b-0d83-45e8-a14e-8428b6efd788"}`.
3. The build version is `1.0.<run_number>` (`MARKETING_VERSION` in the
   workflow). Report the build number once kicked off; watch the run and
   report green/red.

Signing is solved: unsigned archive → ad-hoc entitlement stamp → cloud-signed
export → verify. Identifiers/keys are mapped in HANDOFF.md §"Identifiers".
Never auto-build on a normal push.

---

## 7. Conventions, patterns & landmines

- **Cache coherence — the #1 bug class.** All list/ranking mutations must go
  through **`RankingStore`** (e.g. `createList`, `deleteList`, `commit`), which
  reconciles the **single shared cache** against the server. Do NOT keep a
  parallel per-screen `@State` copy and mutate it optimistically — that's how
  "phantom" deleted lists and stale rankings happen. Surface failures
  (`ToastCenter.saveFailed()`); never swallow a write error with a bare `try?`.
- **Silent contract drift** is the historical enemy: correct-looking Swift over
  a server schema that quietly changed, hidden by `try?`. The defense is
  `contract_check.py` in CI plus naming every FK in PostgREST embeds. Hot-path
  swallows should log via `SupabaseService.logSwallowed`.
- **Dates:** `watch_date` / `watched_on` are **date-only** columns and MUST
  stay `String` in Swift — they can't decode as `Date`. (Comments in code say so.)
- **Images:** `ImageRenderer` (used for the share ticket) can't wait on async
  image loads — pre-fetch posters/avatars as `UIImage` first. Avatar URLs are
  cache-busted with `?t=<timestamp>`; the image cache keys on the full URL, so
  the bust works.
- **Push tokens:** `register_device_token` upserts `on conflict (token) do
  update set user_id = auth.uid()` — a token reassigns to the new signer, so
  there's no notification leak on a shared device.
- **iOS version floor is 17**; Liquid Glass paths are gated behind
  `#available(iOS 26.0, *)` with equivalent fallbacks (DESIGN.md / ARCHITECTURE.md).
- **New files need no project edits** — XcodeGen's `sources: - Cini` includes
  everything under `Cini/` automatically.

---

## 8. Verifying your work

- **`scripts/contract_check.py`** — the backbone. Signs in as the demo account
  and runs every read query, every read RPC, a Storage avatar upload/delete
  smoke test, and (with `--write`) the mutating RPCs, all against production.
  Green = "All contracts hold." Keep its READS/RPCS lists in sync with
  `SupabaseService.swift` — the select strings are verbatim.
- **`ci.yml`** runs the RankingEngine unit tests, builds/tests the app on a
  simulator, and runs the contract check on every push.
- **The prototype** is the fastest way to *show* a UX change (it renders in any
  browser); the app itself needs Xcode/a simulator (CI has it; this environment
  does not).

When something is verified, say so plainly with the evidence. When a step was
skipped or failed, say that too.
