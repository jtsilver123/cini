# Edge-case audit — 2026-06-10

Full-app sweep: crash-prone patterns (force unwraps, `try!`, `as!`,
division), auth dead ends, list/empty states, and network failure paths.

## Fixed in this pass

| Area | Edge case | Fix |
|---|---|---|
| Auth | Keyboard stuck after tapping outside fields | Tap anywhere dismisses (`FocusState`) |
| Auth | Apple sign-in cancel showed an error | Cancel is silent; real failures show actionable text + error code |
| Auth | Signed up but never confirmed email → locked out with "wrong password"-class errors | "Email not confirmed" now surfaces a **Resend email** button; same affordance right after signup |
| Auth | Trailing space / capitals in typed email → "wrong email" | Email trimmed + lowercased before submit |
| Comments | Failed post ate the draft | Draft restored on failure |
| Profile | Share link force-unwrapped a URL built from username | Falls back to cini.app |
| Build | Final IPA could silently lose entitlements (broke Apple sign-in in build 6) | CI now verifies entitlements inside the exported IPA and fails the build if missing |

## Verified safe (no change needed)

- No `try!` / `as!` anywhere in app code.
- All other `URL(string:)!` are compile-time-constant formats.
- Friend-average division guards `friends.isEmpty`.
- Score math: `rescore_bucket` (SQL) mirrors RankingEngine (Swift) — parity
  tested in production earlier.
- Ranked/watchlist/recs/both-want-to-watch screens all have empty states;
  private accounts show the follow-gate hint instead of an empty list.
- Notifications list, feed, taste profile, leaderboard: empty states exist.
- Unknown notification kinds fall through to a generic headline (app and
  send-push edge function both).
- Push: simulator/denied-permission registration failures are silently
  tolerated — in-app notifications are unaffected.
- pg_net push trigger swallows its own errors so a push outage can never
  block ranking/commenting writes.

## Known gaps (acceptable for TestFlight, revisit before App Store)

- No offline banner; failed TMDB searches show an empty result list
  rather than an error toast.
- `send-push` accepts unauthenticated calls (it can only re-deliver real
  notifications to their rightful owner); tighten with a shared secret
  header when convenient.
- Feed pagination: first page only.
