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


# iPhone UX pass — 2026-06-11

| Area | Issue | Fix |
|---|---|---|
| Auth | Content overflowed on small iPhones with the keyboard open | Screen scrolls when space runs out (layout unchanged otherwise); interactive keyboard dismissal |
| Log flow | Double-tapping "Okay" started two ranking sessions (could double-commit) | Phase guard |
| Log flow | Heart/comment glyphs in "What your friends think" looked tappable but were decorative | Removed |
| Movie detail | Ellipsis in the toolbar was a dead image | Real menu: add/remove watchlist, watch trailer |
| Feed | Share on a movieless event produced a broken /movie/0 link | Share hidden when there's no movie |
| Profile | 8 sequential network calls -> >1s of visible stagger | All parallel (async let); pull-to-refresh added |
| Lists | 4-digit rank numbers clipped | Min-width column |
| Search | No feedback while results loaded; no quick clear | Inline spinner while searching; (x) clears the query |
| Leaderboard | Invite button was white-on-gold (rebrand leftover) | Velvet fill |

Verified OK in the same pass: movie detail loads parallel; chat send is
double-tap guarded; comments composer can't double-send; Your Lists
headers already frozen; system back gestures intact everywhere
(navigationDestination throughout); haptics on log-flow actions; empty
states on all lists; sheet detents on all pickers.


# Audit pass 3 — direct recs / calendar / growth (2026-06-11)

| Area | Issue | Fix |
|---|---|---|
| Dates | Fixed-format DateFormatters (Gracenote times, release calendar, watch dates) lacked en_US_POSIX — misparse on 12-hour/non-Gregorian device settings, breaking showtimes entirely for those users | POSIX locale on all three |
| Direct recs | Same rec could be re-sent repeatedly = notification spam | Unique (sender, recipient, movie); re-send updates the note silently |
| Pipeline | Builds 33-35 failed at UPLOAD with ITMS-90382 (Apple's daily TestFlight upload limit — ~35 builds in 24h) | Code confirmed healthy (CI green, archive+export+entitlement verify all passed); stand down triggers until the cap resets, then ship ONE build |

Verified clean: SendRecSheet double-send guarded, empty state, note cap;
DirectRecRow embeds decode (FKs repointed at profiles); myMovieDetails
absent-row handling; release calendar row buttons vs row taps; contacts
fetch runs off-main; recs v2 SQL semantics.
