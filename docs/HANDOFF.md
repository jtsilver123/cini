# HANDOFF — read this first in any new session

**STATUS: Cini IS on TestFlight** — round 6 (run 27311568113, commit
3d728a5) uploaded successfully and the user has it installed. The loop
below continues for follow-up builds.

**Open thread: Apple sign-in fails on device** ("didn't complete" =
ASAuthorization fails before Supabase is ever called). Portal capability
verified ENABLED via ASC API (bundle resource D2B3UT2M3J has
APPLE_ID_AUTH). Diagnosis: the unsigned-archive strategy meant the
`com.apple.developer.applesignin` entitlement was never embedded in the
code signature. Fix shipped: archive now signs with cloud-managed
distribution signing (auth-key flags + `-allowProvisioningUpdates` on the
ARCHIVE step; `CODE_SIGN_IDENTITY[sdk=iphoneos*] = Apple Distribution` at
the Cini TARGET level in project.yml so SPM targets stay automatic).
Round 7 FAILED (automatic signing rejects a manual distribution
identity). Round 8 strategy: unsigned archive + ad-hoc entitlement stamp
before export + a CI step that verifies the final IPA contains
applesignin/aps-environment (fails the build otherwise).

Push notifications: full pipeline shipped — device_tokens table + RPC
(migration 0007), notifications trigger -> pg_net -> send-push edge
function (deployed, verify_jwt false), PushManager registers tokens after
sign-in, aps-environment entitlement added. BLOCKED ON USER: APNs auth key
(.p8) — set function secrets APNS_KEY_P8 / APNS_KEY_ID / APNS_TEAM_ID via
`supabase secrets` or Dashboard -> Edge Functions -> send-push -> Secrets.

Email confirmation: branded template at supabase/templates/confirm_signup.html
(user pastes into Dashboard -> Auth -> Emails -> Confirm signup);
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
  Supabase MCP in new sessions connects to it). All 6 migrations applied;
  advisors clean; pg_cron nightly taste-match scheduled
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
- CI (`ci.yml`): engine tests (39) + app build + app tests (12) on simulator
  — last verified green at commit 9857776; later commits only touched
  workflows/prototype
- Live prototype: https://jtsilver123.github.io/cini/prototype/ — deploys
  via `pages.yml` on push (Pages source = GitHub Actions)
- Privacy policy: https://jtsilver123.github.io/cini/privacy.html
- `Cini.xcodeproj` committed (generated on macOS runner); regenerate with
  `generate-xcodeproj.yml` workflow_dispatch after project.yml changes

## User-side remaining (after a green build)

1. App Store Connect → TestFlight tab → Internal Testing group → add self;
   install TestFlight app on iPhone → install Cini
2. First on-device pass: Apple sign-in tap-test, rank a movie, import
3. Before App Store submission: real device screenshots, app privacy
   questionnaire, demo account for review; see docs/APP_STORE_CHECKLIST.md
4. Security hygiene: rotate `sb_secret` Supabase key, revoke old Apple key
   J4369F4GMF, eventually rotate ASC_KEY_P8 (all passed through chat)
