# HANDOFF — read this first in any new session

**STATUS (2026-06-11 evening): preparing App Store submission.** Build
1.0.37 (run 27358267832, commit d608b08) is on TestFlight; the NEXT
build (user-requested, gated on CI for 46e2e6d) carries the big
data-layer fixes below plus push deep links and final UI polish.
Migrations through **0028** applied to prod and mirrored in
supabase/migrations/.

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

**Marketing site is live**: https://jtsilver123.github.io/cini/ (landing
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
  Supabase MCP in new sessions connects to it). Migrations 0001–0028
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
- CI (`ci.yml`): engine tests (39) + app build/tests on simulator + the
  live Supabase contract check — green through 46e2e6d-era commits
- Live prototype: https://jtsilver123.github.io/cini/prototype/ — deploys
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
