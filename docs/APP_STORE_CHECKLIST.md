# Cini — App Store launch checklist

Status legend: ✅ done · 🔶 in progress · 👤 requires Jake (account owner)

## Code & infrastructure

- ✅ RankingEngine: 39 unit tests + ~13 app tests, green on CI every push
- ✅ iOS app compiles on CI (Xcode 26.4.1, macos-26 runner, zero warnings)
- ✅ Production Supabase live (`npumchnkbcajyuhurgez`): migrations 0001–0026
  applied; anon/PUBLIC execute revoked from all RPCs (0025); security
  advisors clean — remaining WARNs are intentional authenticated RPCs,
  and leaked-password protection is a Supabase Pro feature (N/A on the
  free plan; nothing to do)
- ✅ TMDB key live-verified and wired into the build
- ✅ Gracenote showtimes live (key in Secrets.xcconfig, client-key pattern)
- ✅ TestFlight pipeline automated: GitHub Actions archive → cloud-sign →
  entitlement check → upload (`testflight.yml`, manual trigger only)
- ✅ App icon (1024×1024, asset catalog)
- ✅ Website live at https://jtsilver123.github.io/cini/ — landing page,
  privacy.html, terms.html; linked from Settings and the sign-in screen
- ✅ Support contact everywhere: jtsilver123@gmail.com (in-app, site, legal)
- ✅ Account deletion in-app (Settings → Delete account, server-side cascade)
- ✅ UGC moderation: report + block (with confirmation) on notes, comments,
  and profiles; spoiler blurring; zero-tolerance clause in terms.html
- ✅ Sign in with Apple primary, email fallback
- ✅ Demo account for App Review: appreview@cini-demo.com / CiniReview2026!

## Accounts & keys (👤 only Jake can do these)

1. ✅ Apple Developer Program — enrolled; TestFlight uploads working.
2. 👤 **Revoke the old App-Manager API key `J4369F4GMF`** in App Store
   Connect → Users and Access → Integrations (superseded by `2S66TTGY5Q`).
3. 👤 Eventually rotate the Supabase `sb_secret_` key and the ASC `.p8`
   key (both were shared in chat early on). Not launch-blocking.

## App Store Connect submission (👤 with my step-by-step help when ready)

- App record: bundle ID `app.cini.ios`, name "Cini"
- Marketing URL: https://jtsilver123.github.io/cini/
- Support URL: https://jtsilver123.github.io/cini/ (or mailto)
- Privacy Policy URL: https://jtsilver123.github.io/cini/privacy.html
- App privacy questionnaire: collects email, username, user content,
  contacts (matched once, not stored, not linked); no tracking, no ads
- Age rating questionnaire (12+ suggested: infrequent mature movie themes
  via TMDB artwork/titles)
- Screenshots: 6.9" and 6.5" iPhone sets from the real app on device
- Review notes: include the demo account credentials above

## Pre-submission functional pass (on device, latest build)

- [ ] Sign up with email; sign in with Apple
- [ ] Onboarding: name + profile photo on the username step; initials
      avatar when no photo
- [ ] Search → rank a movie end-to-end (sentiment → comparisons → enrichment)
- [ ] Re-rank ("Rank again"), Want to Watch toggle, stealth mode
- [ ] Follow a second account; verify feed events + friend scores + RLS
      (private notes invisible to the other account)
- [ ] Report and block from a public note (block should confirm first)
- [ ] Where to Watch + Showtimes on a current title
- [ ] Letterboxd import (ZIP with custom lists) + in-app success toast
- [ ] Account deletion path
- [ ] Terms / Privacy / Contact Support links open from Settings

## Known v1 gaps (acceptable for launch, tracked)

- Letterboxd import matches the first 40 titles immediately, rest lazily
- Stats / year-in-review parked until there's data to show
- Film "likes" (Letterboxd-style hearts on movies) deliberately skipped
