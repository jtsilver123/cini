# cini

**Beli for movies.** Log what you've watched, rank it through head-to-head
comparisons (never star ratings), and get a personal, fully-ordered list with
derived 0–10 scores. Follow friends, compare taste, race the leaderboard,
keep your streak alive.

## How ranking works

1. **Sentiment** — Loved it / It was fine / Didn't like it.
2. **Head-to-head** — binary-search insertion inside the bucket: ~log₂(n)
   "Which did you like more?" matchups, with a "Too tough to call" skip that
   places the movie adjacent to its opponent.
3. **Scores** — derived from rank position and recalculated on every insert:
   Loved 6.7–10.0 · Fine 3.4–6.6 · Disliked 0–3.3. Scores are relative
   positions, never absolute ratings.

The whole mechanic lives in [`RankingEngine`](RankingEngine/), a pure Swift
package with zero UI dependencies and a full unit test suite. The same math
is mirrored server-side in the `rank_insert` Postgres RPC so list state stays
transactional.

## Stack

- **SwiftUI, iOS 17+** — Swift Concurrency throughout, MVVM with
  `@Observable` stores. Liquid Glass (iOS 26/27) adopted via availability
  checks in the design system; earlier OSes get equivalent fallbacks.
- **Supabase** — Auth (Sign in with Apple + email), Postgres with RLS,
  Realtime-ready feed, Storage for avatars.
- **TMDB** — search, metadata, cast, trailers, and watch providers
  ("Where to Watch").
- **MovieGlu** (optional) — showtimes near a zipcode.

## Repository layout

```
RankingEngine/        Pure Swift package: buckets, binary insertion, scoring (+tests)
Cini/                 iOS app
  App/                Entry point, session, 5-tab root
  DesignSystem/       Theme tokens, pills, score badges, glass adoption
  Models/             Domain models
  Services/           TMDB, Supabase, RankingStore, Showtimes
  Features/           Feed · Lists · Search · Leaderboard · Profile ·
                      LogFlow · MovieDetail · Onboarding
supabase/migrations/  Schema, RLS policies, transactional RPCs
docs/                 Architecture notes
```

## Getting started

1. **Generate the Xcode project** (requires [XcodeGen](https://github.com/yonaskolb/XcodeGen)):

   ```sh
   xcodegen generate
   open Cini.xcodeproj
   ```

2. **Secrets**: copy `Cini/Resources/Secrets.example.xcconfig` to
   `Secrets.xcconfig` and fill in your TMDB key and Supabase project values.
   Set it as the project's configuration file. MovieGlu keys are optional —
   without them the Showtimes UI shows a graceful "coming soon" state.

3. **Supabase**: create a project, then apply migrations in order:

   ```sh
   supabase db push   # or run supabase/migrations/*.sql in the SQL editor
   ```

   Enable Sign in with Apple under Auth → Providers. Optionally schedule
   `select public.refresh_taste_matches()` nightly with pg_cron.

4. **Run the engine tests** (works on macOS or Linux — no Xcode needed):

   ```sh
   cd RankingEngine && swift test
   ```

## v1 non-goals

No DMs, no group guides authoring, no ticket purchasing, no TV
episode-level tracking (shows rank as whole seasons), no Android. The
schema's `media_kind` and the feed's event model leave room for all of these.
