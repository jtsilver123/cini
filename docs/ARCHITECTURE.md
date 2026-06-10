# Cini architecture

## RankingEngine (pure Swift package)

The product's core is a value-type state machine, deliberately isolated from
UI and persistence:

- `Sentiment` — three buckets with fixed score bands (Loved 6.7–10.0,
  Fine 3.4–6.6, Disliked 0–3.3). Buckets are totally ordered, so the global
  list is just loved ++ fine ++ disliked.
- `InsertionSession` — binary-search insertion. The candidate range
  `[low, high]` over bucket slots halves on each answer; "Too tough to call"
  short-circuits, placing the new title immediately below its opponent.
  Empty bucket ⇒ the session starts complete (first movie ever / first in
  bucket need zero comparisons).
- `RankingList` — bucket arrays + sentiment index. `commit` clamps the
  resolved position so a stale session can never corrupt the list.
  Re-ranking removes the entry first, so it can't be its own opponent.
- `ScoreCalculator` — linear interpolation across the bucket band; a
  single-item bucket gets the top of its band (your only loved movie is a
  10.0). Scores are **recomputed on read** (`scoredItems`), making "recalculate
  the entire list after every insertion" automatic.

Ties: repeated skips still yield a strict total order (positions are
distinct); displayed scores may collide after rounding, which is fine.

## Persistence model

Client is authoritative during a session; Postgres is authoritative across
devices. Every committed insertion calls the `rank_insert` RPC, which:

1. takes a per-user advisory lock (serializes concurrent edits),
2. closes the gap left by a re-ranked row,
3. shifts positions ≥ insertion point,
4. rescores the bucket with the same linear formula,
5. clears the movie from the watchlist,
6. bumps the weekly streak,
7. emits `feed_events` + watchlist notifications.

`rescore_bucket` in SQL and `ScoreCalculator` in Swift are intentionally the
same math — the smoke test in CI asserts the 10.0 / 8.4 / 6.7 progression on
both sides.

## Visibility (RLS)

`can_view(owner)` is the single policy primitive: owner, public account, or
follower of a private account. Private notes are owner-only regardless.
Taste matches are written by the nightly job (service role) and readable
only by their endpoints.

## Taste match

Spearman rank correlation over commonly-ranked titles (PG's `corr` over
rank() — equivalent to Spearman's ρ since ranks have no heavy ties), mapped
from [-1, 1] to a 0–100%. Cached in `taste_matches`, refreshed nightly via
`refresh_taste_matches()`; pairs with < 3 common titles get no match.

## Recs

v1 recs = TMDB similar-titles seeded by the user's top-ranked movie, filtered
to unwatched. The intended v2 blend (friends' high rankings weighted by match
%) has its data model in place: `rankings` × `follows` × `taste_matches`.

## iOS 26/27 design adoption

Liquid Glass is mandatory in iOS 27, so glass is centralized in the design
system rather than scattered:

- `PillButton` → `.glassProminent` / `.glass` button styles,
- `glassCapsule()` view modifier for custom surfaces (filter pills, thumbs),
- `RootTabView` → native `Tab(role: .search)` + `.tabBarMinimizeBehavior`,

each behind `#available(iOS 26.0, *)` with visually-equivalent fallbacks down
to the iOS 17 floor. New iOS 27 refinements (content diffusion, edge
treatment, the user transparency slider) apply automatically because we use
system materials instead of hand-rolled blurs.

## Deliberate v1 seams

- `media_kind` on `movies` — TV/doc/anime categories share the movie pipeline.
- `feed_events.payload` JSONB — new event kinds without migrations.
- `ShowtimesProviding` protocol — swap MovieGlu for another showtimes vendor.
- Leaderboard "Photos" metric is a stub pending a `photos` table.
