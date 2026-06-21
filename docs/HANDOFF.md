# HANDOFF — read this first in any new session

> **New here? Read `CLAUDE.md` (repo root) first** — it's the operating
> manual (golden rules, repo map, workflow, build policy). `docs/DESIGN.md`
> is the design system. This file is the running status log + build history.

**STATUS (2026-06-15): live on the App Store, iterating on UX polish.**
Migrations through **0061** applied to prod and mirrored in
`supabase/migrations/` (latest: `0061_featured_engagement.sql`). Edge functions
deployed + mirrored: `send-push`, `import-upload`, `availability-alerts`,
`showtime-alerts`, `phone-login`. The marketing site + prototype now live on
the custom apex domain **trycini.com** (CNAME in repo root, shipped in the
Pages artifact); App Store Connect URLs + trycini.com DNS are user-side steps.
A user-requested build was last triggered off `claude/ecstatic-cori-k7s2n0`
(CI green on the head commit).

**Recent work (2026-06-15 session):**
- **Domain → trycini.com.** Every in-app/on-site link (invite `/i/`, import
  `/import/`, legal pages, share-card site line) repointed to the apex domain;
  `CNAME` added and copied into `_site/` by `pages.yml`. Marketing site's
  closing CTA changed from "request beta access" to App Store download.
- **Phone-first signup hardened.** Phone step now catches an already-registered
  number *before* email/password via `phone_available` RPC (migration 0060,
  callable by `anon`); friendly "already on Cini — sign in" message.
- **Onboarding fixes.** "You're in!" Beli-style welcome step (auto-followed
  founder); the "Invited by someone else?" alert's **Save** button now actually
  normalizes/keeps the handle (was a no-op), **Cancel** discards, and the
  inviter handle is `@`-stripped before `redeem_invite_from` (silent no-match
  bug). Per-account onboarding gating via `cini.onboardedUserIDs`.
- **Welcome carousel** (`WelcomeView`): three slides now show in-app mockups
  (compare / ranked list / friends) instead of lone icons; custom page dots
  from adaptive `Theme` tokens (the default UIPageControl dots washed out in
  light mode).
- **Invite flow:** `InviteSheet` auto-populates the contact list on open
  (no "Find friends" tap) unless contacts were previously denied. The old
  invite-to-unlock mechanic (`FeedUnlockCard`, `FeatureDetailSheet`, referral
  credits, the "Unlock Features" screen) has been removed — every feature is
  available to everyone; invites now just produce a mutual follow.
- **Follow + approve** (private accounts, migration 0057): `request_follow` /
  `respond_follow_request` / `incoming_follow_requests`; followers and
  following can differ. **Founder auto-follow** on signup (0056). **New
  notifications** (0058–0059): saved-from-your-taste, weekly streak push, and a
  hashed/opt-in/removable **contact_joined** ("X just joined") that names the
  joiner. `send-push` (v12) has copy for every new kind.
- **Settings rebuilt** Beli-style two-level (`AccountSettingsView` →
  Your account / Notifications / Privacy / Your app / Help); notification prefs
  sectioned. Private-account toggle + "Remove synced contacts" in Privacy.
- **App Store audit pass (this session):** fixed the dead onboarding Save
  button + inviter `@` normalization; "Create & add" list quick-action no longer
  shows a false success toast when the add fails; added `lineLimit(1)` to member
  rows / rec-friend rows / profile display name. Account deletion, legal/support
  links (all trycini.com), Info.plist usage strings, and Sign-in-with-Apple
  (not required — email/phone auth) all verified compliant.

- **Featured release goes in-feed + first-party engagement (migration 0061).**
  `PromotedReleaseCard` now flows into the feed Instagram-style (after the 4th
  post, not pinned on top), mirrored in the prototype. Engagement is logged
  first-party only — `featured_events` table + `log_featured_event` RPC
  (impression/open/add); read aggregates via `featured_engagement_stats()`
  (service-role only, run from the Supabase SQL editor). No IDFA, no third
  party, so it's not Apple "tracking" — no ATT prompt. Privacy policy updated
  to disclose it and soften the "no ads" wording to "no third-party ads."

**Recent UX/data work (2026-06-14 session):**
- **Avatar fix + crop.** Root cause of "profile photo won't update" was a
  missing **SELECT** policy on the `avatars` Storage bucket (an upload's
  `INSERT … RETURNING` needs SELECT; Storage returns 400 on the RLS deny) —
  fixed in migration **0042** (live, so it works on existing builds too).
  Added a native square crop (`CropImagePicker`) + one orientation-safe
  avatar path (`AvatarImage.jpeg`). `contract_check.py` gained a **Storage
  upload/delete smoke test** so this class of gap can't slip CI again.
- **Feed `(+)` reflects ranked state.** `ArtworkQuickActions` is now
  ranked-aware (green check + "rank again", bookmark hidden once watched),
  matching the movie page.
- **Rank result redesign.** New `RankTicket` (one source of truth for the
  in-app result card and the shared image): personal header (avatar + name +
  @handle + CINI marquee) over the admit-one ticket. **Two-step reveal** —
  the score "calculates" (`ScoreRevealPlaceholder`: spinning arc + flickering
  number, auto-reveals, no tap) then springs in with a haptic + ripple
  (`ScoreRevealRing`). All mirrored in the prototype.
- **Cache-coherence sweep.** All list create/delete now route through
  `RankingStore` (fixed "phantom" deleted lists). `import-upload` now surfaces
  a 500 instead of silently returning ok on a failed status write.
- **Movies & TV ranked SEPARATELY (migration 0043).** `RankingStore` keeps one
  `RankingList` per kind; `rank_insert`/`rank_remove`/`rescore_bucket` scope by
  `(user, bucket, media_kind)`. Comparisons never cross kinds; first-of-kind
  skips comparisons; per-kind `#N` everywhere (Top-3 = films only, profile
  Watched drill-down split).
- **Full end-to-end audit (migration 0044).** Fixed: `home_zip` (location PII)
  moved off the world-readable `profiles` table to an owner-only
  `user_locations` table + `set_home_zip` RPC (showtime-alerts reads it there);
  `rescore_bucket` search_path pinned; avatars SELECT scoped to owner (no
  listing); `import_movie_details` media_kind clamped; `moveRanked` and
  `commit` now revert + signal on a failed write instead of faking success.
  Push pipeline audited end-to-end (all 11 kinds covered; crons active).

**The silent-contract-drift saga (critical context):** three production
features were broken invisibly because server schema drifted under
correct-looking Swift, all swallowed by `try?`:
1. likes table made `feed_events→profiles` embeds ambiguous (PGRST201)
   → profile Activity empty + feed serving stale disk cache. Fixed by
   naming FKs in every embed.
2. `direct_recs` had no FK to movies (PGRST200) → friend-recs inbox
   never loaded. Fixed in migration 0027.
3. `notifications_kind_check` was never updated for direct_rec /
   invite_joined / watchlist_showing → **sending a rec, invite
   redemption, and showtime alerts all rolled back entirely**. Fixed in
   migration 0028 (+ cleared showtime_notices so alerts re-fire).

**The systemic guard: `scripts/contract_check.py`** executes every app
query/RPC verbatim against production; it runs as a CI job
(`contract-check`) on every push and turns red on any schema drift.
`--write` mode also exercises mutating RPCs as the demo account. A deep
decode audit verified all structs/dates/optionality/embeds against live
JSON — clean. Swallowed errors in hot paths now log via OSLog
(`SupabaseService.logSwallowed`). watch_date/watched_on MUST stay String
(date-only columns can't decode as Date — comments in code explain).

**Marketing site is live**: https://trycini.com/ (landing
+ terms.html + privacy.html, brand-matched; pages.yml publishes them).
Support email everywhere: jtsilver123@gmail.com (NOTHING bettercampus).
Paste-ready App Store metadata: docs/APP_STORE_LISTING.md.
Leaked-password protection: N/A on the free Supabase plan — do not raise.

Apple sign-in on device: RESOLVED (unsigned archive → ad-hoc entitlement
stamp → cloud-signed export → verify step; in testflight.yml since
build 8).

Push notifications: full pipeline shipped — device_tokens table + RPC
(migration 0007), notifications trigger -> pg_net -> send-push edge
function (deployed, verify_jwt false), PushManager registers tokens after
sign-in, aps-environment entitlement added. APNs key 24TJV4TPU4 is in
Supabase Vault (service-role accessor get_apns_secrets(); send-push falls
back to it) and was validated against production APNs (BadDeviceToken =
auth OK). Push is end-to-end once a build-8+ device registers a token.

Email confirmation: user kept Supabase's default template (branded one
still in supabase/templates/confirm_signup.html if wanted later);
app handles unconfirmed accounts with a Resend button. Edge-case audit
recorded in docs/EDGE_CASES.md.

Also shipped since round 6: brand refresh (marquee gold #E8B64C +
velvet red #A8352A on warm charcoal #131011, DM Serif Display bundled via
UIAppFonts, new marquee app icon), Theme tokens renamed teal→marquee,
tealDeep→velvet, tealSoft→marqueeSoft; activity-style list rows +
"You both want to watch" shared list; frozen feed header; AuthView
keyboard dismissal + granular Apple error codes.

## Build history (context for future failures)

The `TestFlight` GitHub Actions workflow (`.github/workflows/testflight.yml`)
has failed 5 times, each failure narrower — archive ✓ and export ✓ since
run 4; we are now iterating on Apple's upload validator only:

1. Run 1: dev-profile/devices error → fixed (distribution path)
2. Run 2: CLI signing override leaked to SPM targets → fixed (archive unsigned)
3. Run 3: archive ✓ → export failed: "Cloud signing permission error" —
   API key was App Manager; needs **Admin** → user created Admin key
4. Run 4 (id 27310404254): upload → ITMS-90474 "no orientations specified"
   → added Portrait to Info.plist
5. Run 5 (id 27310939967): upload → ITMS-90474 variant: bundle is
   iPad-capable so Portrait-only is rejected (iPad multitasking needs all
   four). Root cause: XcodeGen writes a TARGET-level default
   TARGETED_DEVICE_FAMILY="1,2" that overrode our project-level "1".
   → fixed: TARGETED_DEVICE_FAMILY "1" moved into the Cini target settings
   in project.yml, UIRequiresFullScreen=true added,
   UIApplicationSupportsMultipleScenes set false, committed pbxproj patched.
   Round 6 triggered. NEXT STEP: find the latest testflight.yml run via
   `actions_list` (list_workflow_runs, resource_id testflight.yml,
   per_page 1 — parse the oversized JSON overflow file with python),
   then `get_job_logs` (failed_only) if red; repeat until green.

### iPad support enabled (user directive, 2026-06-14)

The app is now a **universal** binary (`TARGETED_DEVICE_FAMILY: "1,2"` at
both the project and `Cini` target level in `project.yml`). It runs
**portrait-only and full screen** on iPad — `UISupportedInterfaceOrientations~ipad`
is Portrait + PortraitUpsideDown, and `UIRequiresFullScreen` stays `true`.

This is *not* a contradiction of the run-5 ITMS-90474 rejection above: that
failure was an iPad-capable bundle with portrait-only orientations **and no
`UIRequiresFullScreen`**. The validator's own message offers two fixes —
include all four orientations, OR "set UIRequiresFullScreen to true to opt
out of iPad multitasking." We take the second. With fullscreen opt-out
(plus `UIApplicationSupportsMultipleScenes` = false), portrait-only on iPad
is accepted. Do NOT revert device family to "1" — iPad support is intended.

No layout code changed: every screen is adaptive SwiftUI on `NavigationStack`
(no deprecated `NavigationView`/split-view behavior), with no `UIScreen`/
size-class/idiom branching, so it reflows to the iPad canvas automatically.
Portrait content is simply wider on iPad; a future polish pass could cap
content width for a more designed look, but it is functional as-is.

### UI PRINCIPLE (user directive, 2026-06-11)

**Re-use UI locations and components.** Identical actions live in
identical places everywhere ((+)/bookmark = scrimmed circles bottom-right
on artwork via ArtworkQuickActions; scores = trailing ScoreBadge;
member rows = MemberRow). Prefer extracting a shared component over
duplicating a pattern, so placements physically cannot drift.

### BUILD POLICY (user directive, 2026-06-11)

**Never trigger a TestFlight build unless the user explicitly asks.**
Commit and push code freely; CI validates every push. Builds are batched
and shipped on request only — Apple caps uploads per app per day
(ITMS-90382) and we burned a full day's quota on auto-triggers.

### How to re-trigger a build (Claude can do this via MCP)

`actions_run_trigger` → workflow `testflight.yml`, ref
`claude/ecstatic-cori-k7s2n0`, inputs:
`{"issuer_id": "a3b57c9b-0d83-45e8-a14e-8428b6efd788"}`

### Likely remaining issues to check in run-4 logs, in order

- Export step: cloud signing cert creation (Admin key should fix; verify the
  new key was actually picked up — `ASC_KEY_ID: 2S66TTGY5Q` is inlined in the
  workflow env; secret `ASC_KEY_P8` was updated by the user)
- Bundle ID `app.cini.ios` may lack the **Sign in with Apple** capability in
  the developer portal → profile/entitlement errors. Fix: user checks the
  capability at developer.apple.com → Identifiers → app.cini.ios, OR remove
  the entitlement from project.yml temporarily to get a first build out
- `altool --upload-app` auth or missing app record (app record EXISTS —
  user created it; name was "Cini — Rank Every Film" variant since "Cini"
  was taken)
- Unsigned-archive export quirk: if export complains about missing
  application-identifier/entitlements, switch strategy to signed archive
  with cloud signing: remove CODE_SIGNING_ALLOWED=NO and instead pass
  `-allowProvisioningUpdates` + auth key flags on the ARCHIVE step with
  `CODE_SIGN_STYLE=Automatic` only (no identity override) — now possible
  since Admin key enables cloud signing end-to-end

## Identifiers / credentials map

- Apple Team ID: `VRPVPJAN9G`
- ASC API key (Admin): ID `2S66TTGY5Q`, Issuer `a3b57c9b-0d83-45e8-a14e-8428b6efd788`,
  private key in GitHub secret `ASC_KEY_P8` (repo Settings → Secrets → Actions)
- Old App-Manager key `J4369F4GMF`: unused — user should revoke
- Bundle ID: `app.cini.ios` · App record created in App Store Connect
- Supabase project: `npumchnkbcajyuhurgez` (user's personal org; the
  Supabase MCP in new sessions connects to it). Migrations 0001–0044
  applied; advisors clean (SECURITY DEFINER WARNs are intentional
  authenticated RPCs; leaked-password WARN is N/A on free plan); pg_cron:
  nightly taste-match + predicted-cache-nightly
- App Review demo account: appreview@cini-demo.com / CiniReview2026!
  (has seeded data; also used by scripts/contract_check.py)
- TMDB key: in `Cini/Resources/Secrets.xcconfig` (committed; client-safe)
- Apple provider in Supabase: ENABLED, Client ID `app.cini.ios`, no secret
  (native flow) — verified by token probes (forged token → "Bad ID token";
  disabled provider → "provider is not enabled")
- Email auth: fully E2E tested in production (admin-create → password login
  → RLS profile read → cleanup)

## What's already done & verified (do not redo)

- Full iOS app (SwiftUI, iOS 17 floor, Liquid Glass via availability):
  ranking flow in Beli's order, unified profile (Activity | Taste Profile
  tabs, streak card, no school/challenge/guides), feed + notifications
  (DB triggers tested in prod), leaderboard (all metrics verified in prod),
  recs engine, shared watchlists, Letterboxd ZIP + Apple Notes import,
  Ask Cini (Apple Foundation Models, on-device), dark cinema brand
- Ask Cini availability ladder (verified June 2026): iOS < 26 → no chat
  entry points anywhere (button hidden, fallback view as defense);
  iOS 26+ but never-eligible hardware (deviceNotEligible) → entry points
  hidden too via `ChatEligibility.canEverBeAvailable`; fixable states
  (Apple Intelligence off, model downloading) → button shows, screen
  explains the fix. iOS 27's rebuilt on-device model arrives
  automatically through `SystemLanguageModel` — no code change needed.
  New iOS 27 APIs (multimodal prompts, `LanguageModel` protocol, Dynamic
  Profiles) need the Xcode 27 SDK, which App Store builds can't use
  until it ships GM (~Sept 2026) — revisit then.
- Content types (user directive, 2026-06-12): Movies and TV Shows are
  the ONLY two categories — Documentaries/Anime were removed from
  MediaCategory (they're genres: searchable and filterable, never
  categories). TMDB parity: similar() routes negative ids to /tv,
  popular() merges /discover/movie + /discover/tv by popularity,
  directedMovies() uses combined_credits so director queries surface TV.
  upcoming() stays movie-only DELIBERATELY — it's the theatrical
  release calendar.
- Rec requests (Beli-style "ask friends for a rec"): feed row under
  YOUR FEED → RequestRecsSheet (multi-select friends, optional
  Movies/TV + genre + note) → `request_recs` RPC (0036; follow +
  not-blocked enforced, pending asks dedupe per pair, 'rec_request'
  notification + push via send-push v8). Recipient: feed banner +
  notification row → RespondRecSheet → multi-select own ranked titles
  (filtered to the ask, falls back to all) → direct recs +
  `complete_rec_request`. Answers land in the requester's Friend Recs.
- Siri actions (`Cini/App/SiriIntents.swift`): App Intents + App
  Shortcuts — add/remove Want to Watch, read the watchlist aloud, open
  a title's page, open the watchlist. The new Siri (iOS 27) drives these
  from natural speech; iOS 17–26 classic Siri uses the registered
  phrases ("Add a movie in Cini") and asks a follow-up for the title.
  Intents hit Supabase/TMDB directly (signed-out → spoken sign-in
  prompt); open-style intents reuse TabRouter's push deep-link plumbing.
- CI (`ci.yml`): engine tests (39) + app build/tests on simulator + the
  live Supabase contract check — green through 46e2e6d-era commits
- Live prototype: https://trycini.com/prototype/ — deploys
  via `pages.yml` on push, alongside the marketing site at the root
- Legal pages: …/cini/privacy.html and …/cini/terms.html (linked from
  Settings and the sign-in screen)
- Push deep links: send-push payload carries kind/movie_id/actor_* and
  PushManager routes taps via TabRouter.shared (movie pushes → movie
  page, follower pushes → profile)
- No committed Xcode project: every pipeline (ci.yml, testflight.yml)
  runs `xcodegen generate` from project.yml, the single source of truth

## User-side remaining (after a green build)

1. App Store Connect → TestFlight tab → Internal Testing group → add self;
   install TestFlight app on iPhone → install Cini
2. First on-device pass: Apple sign-in tap-test, rank a movie, import
3. Before App Store submission: real device screenshots, app privacy
   questionnaire, demo account for review; see docs/APP_STORE_CHECKLIST.md
4. Security hygiene: rotate `sb_secret` Supabase key, revoke old Apple key
   J4369F4GMF, eventually rotate ASC_KEY_P8 (all passed through chat)
