# Cini — App Store launch checklist

Status legend: ✅ done · 🔶 in progress · 👤 requires Jake (account owner)

## Code & infrastructure

- ✅ RankingEngine: 39 unit tests, green on Linux + macOS CI
- ✅ iOS app compiles on CI (Xcode 26.4.1, macos-26 runner, `BUILD SUCCEEDED`, zero warnings)
- ✅ Production Supabase live (`npumchnkbcajyuhurgez`): all 4 migrations applied,
  rank_insert smoke-tested in production, security advisors clean
  (remaining WARNs are intentional authenticated RPCs)
- ✅ TMDB key live-verified (search + watch providers) and wired into the build
- ✅ App icon (1024×1024, asset catalog)
- ✅ Privacy policy hosted: https://jtsilver123.github.io/cini/privacy.html

## Accounts & keys (👤 only Jake can do these)

1. **Apple Developer Program** — enroll at https://developer.apple.com/programs/
   ($99/year, takes 1–2 days to approve). Needed for TestFlight and App Store.
2. ✅ **TMDB API key** — done, wired into Secrets.xcconfig.
   ⚠️ TMDB terms require in-app attribution — the About screen must show
   "This product uses the TMDB API but is not endorsed or certified by TMDB."
3. ✅ **Supabase production project** — done; migrations applied.
   ⚠️ Post-setup hygiene: rotate the `sb_secret_` key (Settings → API Keys)
   and consider changing the database password — both were shared in chat.
4. **MovieGlu** (optional, for Showtimes) — https://developer.movieglu.com
   free tier. Without it the Showtimes sheet shows a friendly "coming soon."

## App Store Connect setup (👤 with my step-by-step help when ready)

- Create the app record (bundle ID `app.cini.ios`, name "Cini")
- App privacy questionnaire (answers derived from privacy.html: collects
  email, username, user content; no tracking, no ads)
- Age rating questionnaire (12+ suggested: infrequent mature movie themes
  via TMDB artwork/titles)
- Screenshots: 6.9" and 6.5" iPhone sets (generate from the running app;
  the prototype screenshots are placeholders, App Store requires real
  device captures)
- Sign in with Apple must be configured in Supabase Auth → Providers with
  the Services ID + key from the Apple Developer account
- Demo account for App Review (email+password signup makes this easy)

## Build & distribute

- Generate project: `xcodegen generate`
- Open in Xcode on a Mac, select your team (automatic signing)
- Product → Archive → Distribute → TestFlight
- (Later: a `fastlane` lane + GitHub Actions with App Store Connect API key
  can automate this — set up once the Apple account exists.)

## Pre-submission functional pass

- [ ] Sign up with email; sign in with Apple
- [ ] Search → rank a movie end-to-end (sentiment → comparisons → enrichment)
- [ ] Re-rank ("Rank again"), watchlist toggle, stealth mode
- [ ] Follow a second account; verify feed events + friend scores + RLS
      (private notes invisible to the other account)
- [ ] Where to Watch sheet on a current title
- [ ] Streak increments after first log of the week; challenge progress
- [ ] Account deletion path (App Review requires it for account-based apps)

## Known v1 gaps (acceptable for launch, tracked)

- Letterboxd import matches the first 40 titles immediately, rest lazily
- Leaderboard "Photos" metric is a placeholder tab
- Comments UI is minimal (like/comment counts land post-launch)
