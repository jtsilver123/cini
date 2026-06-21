# Growth backlog — the 24 recommendations & what we did

A new-user "love it → stay → tell friends" pass. Each item is classified:

- **Built** — new feature/code this pass.
- **Refined** — existed; sharpened or re-gated this pass.
- **Already there** — already well-implemented; no change needed.
- **Skipped (deliberate)** — intentionally not done to keep the app calm /
  respect a prior decision (founder steer: "don't make it overwhelming").

Tag key: `[A]` activation · `[R]` retention · `[Ref]` referral.

---

## Tier 0 — Activation (the first session)

1. **`[A]` "Your taste, decoded" finale — Refined.** The recs finale now reads
   as a payoff ("Your recs, ready · Picked for your taste") once a user has any
   ranks. `OnboardingView.recTutorialStep`.
2. **`[A]` Import as a front-door — Already there.** Onboarding step 3 imports
   from Letterboxd/Apple Notes. `OnboardingView.importStep`.
3. **`[A]` Front-load "rank what you've seen" — Built.** New optional, skippable
   grid step (reusing `SuggestionGrid`): a wall of popular titles, tap to rank.
   Recognition is the fastest way to build taste signal. `OnboardingView.rankSeenStep`.
4. **`[A]/[Ref]` Contact-match "follow your friends" — Already there.**
   `OnboardingView.findFriendsStep` (contacts + suggested + invite).
5. **`[A]` Teach by doing instead of a tour — Already there / kept.** The recs
   finale teaches the swipe/rank gestures; the product tour was kept (heavily
   iterated, founder wanted it). No change.
6. **`[A]` Trim onboarding — Skipped (deliberate).** Each step earns its place
   (profile, friends, import, notifications, grid, recs); we added one *optional*
   step rather than cut. Kept lean, not minimal.

## Tier 1 — Retention (a reason to come back)

7. **`[R]` Tonight's Pick from day one — Refined.** Was gated to day 5 (past most
   churn); now unlocks on taste signal (≥5 ranked titles), and re-checks when the
   rank count changes. `FeedView.tonightUnlocked`.
8. **`[R]` Daily evening push — Already there.** `tonight-pick` edge function +
   hourly cron sends a personalized pick at ~7pm local. `supabase/functions/tonight-pick`.
9. **`[R]` Watchlist streaming / new-season alerts — Already there.**
   `streaming_now` / `season_premiere` notifications + availability cron.
10. **`[R]` Streak visible & rewarding — Already there.** Feed-header streak pill
    + profile stat card with at-risk messaging. (Skipped adding more surfaces —
    would be gamification noise.)
11. **`[R]` "You watched X? rank it" nudges — Already there.** `rate_nudge`.
12. **`[R]` Currently-watching / next episode — Already there.** `CurrentlyWatching`.

## Tier 2 — Referral (sharing, not nagging)

13. **`[Ref]` One-tap share artifacts — Already there.** Rank ticket image,
    "Share my Top 5" card, Taste-Match card, profile/list text share. (Skipped a
    Top-10/taste-image variant — coverage is already strong.)
14. **`[Ref]` Referral unlock — Already there / Skipped extending.** `referral_count`
    + `unlock_feature` + an unlock banner exist; did **not** add a paywall-style
    gate (overwhelm risk).
15. **`[Ref]` Ask friends what to watch — Already there.** `RequestRecsSheet`.
16. **`[Ref]` Auto-prompt share at peaks — Already there.** Rank result screen
    prompts "Share your new #1".
17. **`[Ref]/[R]` Movie-night watch plans — Already there.** `PlanWatchSheet`.
18. **`[Ref]/[R]` Taste-match on member rows — Built.** Match % was computed but
    only shown on the suggestions shelf; now "X% match · @username" (green) shows
    on search results and followers/following via a batch lookup over the existing
    `taste_matches` table (no migration). `SupabaseService.memberMatchPcts`,
    `SearchView`, `FollowListScreen`.
19. **`[Ref]` Profile as identity — Built.** Added a one-line taste headline
    ("Big on Sci-Fi & Thriller, with a soft spot for the 2010s.") atop the Taste
    tab, derived from the same data shown below it. `TasteSummary.headline`.
    (Profile already had top genres, favorite decade, sentiment split.)

## Tier 3 — Polish that compounds

20. **`[A]/[R]` Empty states that teach — Already there.** Watched / Want-to-Watch
    / Recs / taste tabs all have helpful empty states with CTAs.
21. **`[R]` "Why this rec" — Already there.** Rec cards and Tonight's Pick carry a
    reason line ("Because you liked …").
22. **`[R]` Ask Cini starters — Already there.** Personalized, tappable starter
    chips + concierge bar in the chat empty state.
23. **`[R]/[Ref]` Leaderboard competition — Already there / Skipped extending.**
    Leaderboard exists; did **not** add a competitive weekly loop (overwhelm risk).
24. **`[A]` First-launch speed / skeletons — Already there.** Disk-snapshot warm
    start, skeleton loaders, branded launch view.

---

## Summary

- **Built from scratch (3):** #3 onboarding rank grid, #18 taste-match on rows,
  #19 profile taste headline.
- **Refined (2):** #1 recs payoff finale, #7 Tonight's Pick day-one unlock.
- **Already there (~15):** import, find-friends, evening push, watchlist alerts,
  streaks, rank nudges, currently-watching, share artifacts, referral plumbing,
  ask-for-recs, peak-share, watch plans, empty states, why-this-rec, Ask Cini
  starters, skeletons.
- **Deliberately skipped (to keep it calm):** trimming onboarding to the bone,
  removing the tour, a referral paywall gate, a weekly digest, a competitive
  leaderboard.

Takeaway: the app was far more built-out than the list assumed. The real,
high-leverage gaps were the onboarding rank grid (fast taste-building),
day-one Tonight's Pick (early-retention hook), and taste-match everywhere
(makes following feel valuable) — those got built/refined; the rest were
already solid or were left out on purpose to protect the calm feel.
