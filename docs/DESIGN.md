# DESIGN.md — Cini design system

How Cini looks, why, and the rules that keep it consistent. Read this before
adding any screen or component. Tokens and components are **real and current**
(verified against `Cini/DesignSystem/`). When in doubt, reuse — never hand-roll
a color, font, or placement that a token/component already provides.

---

## 1. Brand: the movie palace

Cini is a **1920s–30s movie theater** rendered as an app: a marquee out front,
a velvet-curtained screening room inside. The mood is warm, low-lit, and
premium — not a cold streaming UI.

- **Marquee gold** is the brand accent — every link, active state, and accent.
- **Velvet crimson** fills the primary CTAs (the cinema curtain).
- **Two "rooms" (color schemes):** the dark **screening room** (default) and a
  warm cream **matinee** (light mode). Every token resolves per scheme, so the
  whole app flips with the appearance setting — never hardcode a hex.

---

## 2. Color tokens (`Theme.swift`)

Always use `Theme.*`; each is adaptive (dark / light). Hexes are the dark room.

| Token | Dark hex | Role |
|---|---|---|
| `Theme.marquee` | `#E8B64C` | Brand accent: links, active states, outlines |
| `Theme.velvet` | `#A8352A` | Primary filled CTAs (pills) |
| `Theme.marqueeSoft` | gold @16% | Pressed/selected tint |
| `Theme.gold` | `#D9A93C` | Decorative premiere gold: result ticket, streak flame |
| `Theme.ink` | `#F5EEDF` | Primary text |
| `Theme.gray` | `#A69C91` | Secondary / metadata text |
| `Theme.background` | `#131011` | App background (house lights down) |
| `Theme.surface` | `#1D1719` | Card surface |
| `Theme.surface2` | `#281F20` | Higher elevation (badges, inputs) |
| `Theme.fill` | white @7% | Field / inactive-chip fill |
| `Theme.hairline` | white @10% | Card & badge borders |
| `Theme.cardShadow` | black @45% | Elevation shadow |
| `Theme.scoreGreen` | `#2FBF71` | Score ≥ 6.7 |
| `Theme.scoreAmber` | `#E0A93E` | Score 3.4–6.6 |
| `Theme.scoreRed` | `#D96B6B` | Score < 3.4 |
| `Theme.sentimentLoved/Fine/Disliked` | green/gold/red | The three "How was it?" circles |

`Theme.scoreColor(_:)` returns the right band color for a score — use it
everywhere a score is tinted, so the thresholds never drift.

---

## 3. Typography

Two bundled OFL faces, both via `Theme`:

- **`Theme.display(size)` → "Limelight"** — an Art-Deco titling font that reads
  like a marquee sign. All-caps by nature. Used for the wordmark and big
  section headers. Presets: `Theme.wordmark` (28), `Theme.pageHeader` (32).
- **`Theme.serif(size)` → "DM Serif Display"** — a high-contrast poster didone
  for content that must stay readable in mixed case: **movie/show titles**,
  greetings, the result-ticket title. Preset: `Theme.detailTitle` (36).
- Body / UI text uses the **system font** (SF) with standard weights.

Rule of thumb: **Limelight = signage, DM Serif = titles, SF = everything else.**

---

## 4. Surfaces & elevation

- **`.floatingCard()`** — the standard rounded surface (continuous corners,
  `Theme.surface` fill, soft shadow). The log-flow cards and most panels use it.
- **`HairlineCard`** — a bordered card for list-style content (hairline stroke,
  no heavy shadow).
- Borders are always `Theme.hairline`; shadows always `Theme.cardShadow`.
- **Corner-radius scale** (`Theme.rControl` 12 / `rCard` 16 / `rHero` 22) — one
  set instead of ad-hoc 10/14/18 sprinkled around: fields & chips use `rControl`,
  cards & rows use `rCard`, sheets & floating hero cards use `rHero`.
- Loading never shows blank: **`SkeletonPulse` / `FeedSkeleton`** show the
  *shape* of what's coming.

---

## 5. Component catalog (`Cini/DesignSystem/`)

Reuse these; extend them rather than cloning a pattern.

**Scores & art**
- `ScoreBadge` — the circular score (color from `scoreColor`); optional count
  bubble. The canonical way to show a score.
- `ScoreChip` — small filled score chip (detail hero).
- `PosterView` — poster image with placeholder; `AvatarView` — avatar with
  initials fallback (no generic silhouette when a name exists).
- `CachedAsyncImage` — image loader; cache keys on the **full URL** (so avatar
  `?t=` cache-busts work).

**Actions**
- `ArtworkQuickActions` — the `(+)` / bookmark pair (scrimmed circles,
  bottom-right on artwork). **Ranked-aware:** once a title is ranked it shows a
  green check (tap to rank again) and drops the bookmark, mirroring the movie
  page. This is the single home of that pattern — use it, don't re-create it.
- `PillButton` — primary/outlined/ghost pills; Liquid-Glass on iOS 26+.
- `bookmarkTapped(...)` — the shared watchlist-toggle/save-sheet helper.
- `SaveToListSheet` — "save to Want to Watch / a list" sheet.
- `CropImagePicker` — native square avatar crop (UIImagePickerController
  `allowsEditing`); `AvatarImage.jpeg(from:)` is the one avatar-processing path
  (orientation-safe, 512px, JPEG).

**Result / share**
- `RankTicket` — the cinema "admit-one" ticket, the single source of truth for
  the post-rank result. Backs both the in-app card and the rendered share
  image. Leads with avatar + name + @handle and a `CINI` marquee, then poster,
  title, byline (movies *and* TV), score, rank, streak chip, perforation.
- `ScoreRevealPlaceholder` — the "calculating your score" state (spinning arc +
  flickering number) shown before the score lands.
- `ScoreRevealRing` — the one-shot ripple "ta-da" when the score reveals.
- `RankShareCard` — wraps `RankTicket` with pre-fetched bitmaps for
  `ImageRenderer` (the shareable image).

**Structure**
- `SegmentedPillControl` — segmented control (Leaderboard metrics, Search tabs).
- `MemberRow` — the canonical member/person row.
- `MovieFilters` — the five standard list filters; one bar everywhere.

---

## 6. UI laws (non-negotiable)

1. **Identical actions in identical places.** The same action uses the same
   component in the same spot on every screen, so placement can't drift. `(+)` /
   bookmark = `ArtworkQuickActions` bottom-right on artwork; scores = trailing
   `ScoreBadge`; people = `MemberRow`. Prefer extracting a shared component over
   duplicating a layout.
2. **Movies and TV are equal.** Every list, filter, search, and result treats
   the two identically. TV is never second-class and never mislabeled as a movie
   (the log flow's media chip is a real override).
3. **Socials are shown openly** on profiles — no lock icons.
4. **One contextual banner at a time** — never stack nudges.
5. **Reveal is a moment.** The rank result *calculates* then reveals (see §7) —
   don't shortcut it to an instant number.
6. **Use tokens, not hexes; components, not clones.**

---

## 7. Signature flow: logging & the rank reveal

The log flow (`Features/LogFlow/LogFlowView.swift`) follows Beli's order, in our
brand, as a stack of `.floatingCard()`s over a dimmed scrim:

1. **Title card** — serif title + metadata + ✕.
2. **Category + destination chips** — `[Movies/TV ▾]` and where it files
   (Want to Watch by default, or any of your lists; make a new one inline).
3. **"How was it?"** — the three sentiment circles (Loved / Fine / Disliked).
4. **Enrichment card** — who with, labels, notes, date, photos, stealth → Okay.
5. **Comparisons** — head-to-head "Which do you prefer?" (Undo · Too tough ·
   Skip), powered by the RankingEngine binary-search insertion.
6. **Result ticket** — `RankTicket` with the **two-step reveal**:
   - lands showing **`ScoreRevealPlaceholder`** — a spinning gold arc with the
     number flickering under "Calculating your score…" (it *computes*, no tap);
   - after ~1s the real **`ScoreBadge`** springs in (spring + success haptic)
     with a **`ScoreRevealRing`** ripple — the payoff;
   - **Share** (renders `RankShareCard` to an image) + **Done** arrive *with*
     the score. The personal, branded ticket is meant to be screenshot/shared.

This "rating screen → calculating → score screen" sequence is the emotional
core — keep it satisfying. Mirror any change to it in the prototype.

---

## 8. Liquid Glass (iOS 26/27)

Glass is centralized, not scattered, so iOS 27's mandatory Liquid Glass is one
change point:

- `PillButton` → `.glassProminent` / `.glass` styles;
- `glassCapsule()` modifier for custom glass surfaces (filter pills, thumbs);
- native `Tab(role: .search)` + tab-bar minimize behavior in the root.

Each is behind `#available(iOS 26.0, *)` with a visually-equivalent fallback
down to the **iOS 17 floor**. Use system materials, never hand-rolled blurs, so
iOS 27 refinements apply automatically.

---

## 9. The prototype mirror

`prototype/index.html` is a self-contained web mockup (its own CSS variables and
`I()` icon set mirror `Theme`). **Any user-visible app change must be reflected
here** so the prototype stays a faithful demo. It's also the fastest way to
*show* a UX change without Xcode — it renders in any browser.

---

## 10. Adding a new screen — checklist

- [ ] Background `Theme.background`; cards `.floatingCard()` / `HairlineCard`.
- [ ] Colors/fonts via `Theme.*` only (both rooms tested).
- [ ] Reuse `ScoreBadge`, `AvatarView`, `PosterView`, `ArtworkQuickActions`,
      `MemberRow`, `PillButton`, `SegmentedPillControl` rather than re-building.
- [ ] Movies and TV handled identically.
- [ ] Actions in their canonical positions (UI law #1).
- [ ] Loading shows a skeleton, not a blank.
- [ ] Liquid Glass via the shared helpers, gated for iOS 17 fallback.
- [ ] Mirror the change in `prototype/index.html`.
