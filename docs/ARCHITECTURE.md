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

## Auth & social graph

**Auth** is email **or** phone + password (no third-party/social login, so
Sign in with Apple isn't required). Phone is collected first at signup
(Beli-style) and is a login key: `user_phones` has a unique index on
`phone_key` (normalized). Login-by-phone resolves the number → user id via the
`phone-login` edge function (service-role; never exposed to clients, so no
email leak). Signup checks `phone_available(p_phone)` (SECURITY DEFINER,
granted to `anon`, returns a bare boolean) so a duplicate number is caught on
the phone step before the account is created; `set_phone` still enforces
uniqueness at save time.

**Follow + approve.** Public accounts follow instantly; private accounts use
`request_follow` → a pending row → `respond_follow_request` (approve/decline) →
`incoming_follow_requests` powers the requests inbox. Followers and following
are independent (asymmetric, like Beli/Twitter). Every new account
auto-follows the **founder** on signup (`follow_founder_on_signup`, migration
0056 — Beli's "Judy" pattern) so the feed has picks from day one;
`notify_on_follow` skips the founder so it isn't spammed.

**contact_joined.** Find-friends stores contacts as **one-way SHA-256 hashes**
only (`contact_phone_hashes`, via `store_contacts`; raw numbers/names never
stored, wipeable via `forget_contacts`). When someone later joins and verifies
that number, `notify_contact_joined` pings the people who had them — naming the
joiner. Opt-in (tied to the Find Friends action) and disclosed in the privacy
policy + `NSContactsUsageDescription`.

All of the above flow through the `notifications` table, so the BEFORE-INSERT
mute filter and AFTER-INSERT push trigger (`send-push` → APNs) apply uniformly.

## Taste match

Spearman rank correlation over commonly-ranked titles (PG's `corr` over
rank() — equivalent to Spearman's ρ since ranks have no heavy ties), mapped
from [-1, 1] to a 0–100%. Cached in `taste_matches`, refreshed nightly via
`refresh_taste_matches()`; pairs with < 3 common titles get no match.

## Recs — taste model

`recs_for_user(p_limit)` (migration `0099_recs_taste_v3`) orders the Recs deck
and feeds Ask Cini. It's a content + collaborative hybrid that uses every taste
signal and grows more personal as the user ranks more:

- **Personal score** = your average rating (`mu`) nudged by per-genre and
  per-director *deviations* from that baseline. Deviations pool three signals:
  ratings (full weight), bookmarks (mild positive — "want to watch"), and passes
  (negative — "not for me"). Each deviation is **shrunk toward neutral** by how
  much evidence backs it, so one rating in a genre can't dominate.
- **Friends** = titles followed users rated ≥ 6.7, weighted by `taste_matches`
  %, with a small bonus for multiple friends agreeing.
- **Community** = Bayesian average over all rankings (prior 6.5, weight 5).
- **Adaptive blend**: personal weight = `n/(n+15)` (n = your ranking count), so a
  cold-start user leans on community/friends and a heavy ranker leans on their
  own taste. Friends hold a steady ~0.30 when present. Excludes ranked ∪
  bookmarked ∪ passed titles.

Per-title predicted ratings (Want-to-Watch badges) come from the sibling
`predicted_scores`/`predicted_scores_for` (cached 36h, refreshed nightly); they
still use the v2 genre-average blend — a candidate for the same v3 upgrade.

**Featured release.** The feed's `PromotedReleaseCard` is a first-party
discovery/ad surface: a new release picked from the user's most-ranked genre,
placed inline (Instagram-style) rather than pinned. Engagement is logged
first-party only — `featured_events` (impression/open/add) via
`log_featured_event`; aggregates read with `featured_engagement_stats()`
(service-role only). No IDFA / no third party, so it's not ATT "tracking".
This is the seam for paid promoted placements later (which would need a
"Sponsored" label + the standard ad disclosures).

## Currently Watching & Tonight's Picks

`show_progress` (per-user, per-show season/episode + `caught_up`) tracks a show
you're mid-binge on; starting a show supersedes its Want-to-Watch row, and
ranking it clears the progress (a trigger). It powers the feed's "Friends are
watching" shelf, the profile shelf, and **Tonight's Picks**.

**Tonight's Picks** (`tonight_picks` / `tonight_pick_for`, watchlist-only since
migration 0097) is the feed's daily hook. The app leads the deck with shows
you're mid-binge on (`continue_watching_picks`, migration 0098, caught-up shows
excluded), then fills with your highest-predicted unranked Want-to-Watch titles
that are on a streaming service. Card gestures: swipe LEFT = "not tonight"
(dismiss for the day, no taste signal); swipe RIGHT = open the detail page and
auto-present Where to Watch. The evening push (`tonight-pick` edge function)
uses the same watchlist-only source.

## Admin dashboard

`/admin/index.html` (Cini-branded, public anon key only) reads aggregate KPIs
and trends via `admin_overview` / `admin_trends` / `admin_top_titles` /
`admin_recent_activity` (migration 0100). Each is `SECURITY DEFINER` so it can
aggregate across all users despite RLS, but hard-gates on `is_admin()` (a
founder-uid allowlist) and is revoked from anon — a non-admin call returns
`forbidden`. Login is Supabase email/password or phone OTP.

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
