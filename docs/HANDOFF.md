# HANDOFF — read this first in any new session

**Goal in progress: get Cini onto TestFlight.** Everything else is done and
verified. A fresh Claude session should read this file, then continue the
TestFlight loop below.

## Current blocker (the ONLY open thread)

The `TestFlight` GitHub Actions workflow (`.github/workflows/testflight.yml`)
has failed 4 times, each failure narrower:

1. Run 1: dev-profile/devices error → fixed (distribution path)
2. Run 2: CLI signing override leaked to SPM targets → fixed (archive unsigned)
3. Run 3: archive ✓ → export failed: "Cloud signing permission error" —
   API key was App Manager; needs **Admin** → user created Admin key
4. Run 4 (id **27310404254**, commit b44ac6c): failed after ~3min —
   **logs not yet inspected**. NEXT STEP: pull failed-job logs for run
   27310404254 via the GitHub MCP `get_job_logs` (failed_only), diagnose,
   fix workflow, re-trigger, repeat until green.

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
