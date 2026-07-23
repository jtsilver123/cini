import SwiftUI
import RankingEngine

/// Everything the user adds while logging, gathered before comparisons
/// and persisted after the rank is committed.
struct EnrichmentDraft {
    var watchedWith: Set<UUID> = []
    var watchDate: Date?
    /// "home" or "theater" — how they watched it.
    var watchedWhere: String?
    var notes = ""
    var notesContainSpoilers = false
    var cast: Set<CastMember> = []
    var stealthMode = false
}

/// The log flow, faithful to Beli's stacked-card overlay and its order:
///
///   1. movie title card (serif, metadata, ×)
///   2. [Movies ▾] [Want to Watch ▾] — media type + destination chips
///   3. "How was it?" — three colored circles
///   4. details card — who with, labels, notes, date, stealth… then Okay
///   5. "Which do you prefer?"  A —OR— B   (Undo · Too tough · Skip)
///   6. result card — "Ranked #4 · 8.6" → Done
///
/// Presented full-screen over a dimmed scrim so the app shows through.
struct LogFlowView: View {
    let movie: Movie

    init(movie: Movie) {
        self.movie = movie
        // TV shows open as TV — the chip must never claim a show is a movie.
        _category = State(initialValue: movie.mediaKind == "tv" ? .tvShows : .movies)
    }

    @Environment(AppSession.self) private var appSession
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var category: MediaCategory = .movies
    @State private var sentiment: Sentiment?
    @State private var phase: Phase = .sentiment
    @State private var draft = EnrichmentDraft()
    @State private var session: InsertionSession<Int>?
    @State private var scored: ScoredItem<Int>?
    @State private var pairID = 0
    @State private var enrichRow: EnrichmentCard.Row?
    @State private var movieCast: [CastMember] = []
    @State private var shareImage: Image?
    /// Set when this rank crossed a ranked-count milestone (10th, 25th, …) — the
    /// result screen then offers a celebratory "share your top 5" prompt.
    @State private var milestoneJustHit: Int?
    @State private var showTop5Share = false
    // Two-step reveal: the result lands as a "…" ticket (rating screen),
    // then the score springs in (score screen) — Beli's flow, our brand.
    @State private var scoreRevealed = false
    @State private var didScheduleReveal = false
    /// The reveal needs BOTH gates: the ~1s calculating beat has played
    /// (`beatElapsed`) AND the server confirmed the rank (`commitConfirmed`).
    /// This keeps the ticket instant while never flashing a score for a save
    /// that ends up failing.
    @State private var beatElapsed = false
    @State private var commitConfirmed = false
    /// The save is taking a while (slow/unstable connection) — show a "Saving…"
    /// note on the result screen so the calculating state never feels frozen.
    @State private var saveSlow = false
    @State private var choosing = false   // guards against double-tapping a comparison
    @State private var committing = false  // guards against a double commit (commit can exceed the 200ms tap guard)
    @State private var showDiscardConfirm = false
    /// The streak before this rank committed — lets the reveal tell a streak
    /// that just *advanced* from one that merely held.
    @State private var priorStreak = 0
    // "I'm still watching it" (TV only): reveal a quick where-are-you picker
    // instead of ranking, and mark the show as currently watching.
    @State private var showStillWatching = false
    @State private var swSeason = 1
    @State private var swEpisode = 1
    /// A show's episode structure — lets "I'm all caught up" record the latest
    /// aired episode (not S1·E1) so Currently Watching reflects where you are.
    @State private var showInfo: TMDBService.ExtendedDetails?

    enum Phase {
        case sentiment      // picking a bucket
        case enrich         // details card shown, waiting for Okay
        case comparing      // head-to-head in progress
        case result         // committed; showing rank + score
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Lighter scrim so you can still see the title/list you're ranking.
            Color.black.opacity(0.4)
                .ignoresSafeArea()
                .onTapGesture { if phase == .sentiment { cancel() } }

            ScrollViewReader { proxy in
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 8) {
                        // You can only rank what's out — anything else opens
                        // straight to "not out yet" with a Want to Watch CTA.
                        if !movie.isReleased {
                            titleCard
                            notReleasedCard
                                .padding(.top, 24)
                        } else if phase == .result, let scored {
                            // The result is the whole screen — the earlier cards
                            // fall away so the ticket lands in view, no scrolling.
                            resultCard(scored)
                                .id("result")
                                .padding(.top, 12)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        } else {
                            titleCard
                            categoryCard
                            sentimentCard

                            // TV only: a way out of ranking for a show you
                            // haven't finished — mark where you are instead.
                            if movie.mediaKind == "tv" && phase == .sentiment {
                                stillWatchingCard
                            }

                            // Beli's order: the details card hands off to the
                            // comparison card — it doesn't stack above it, so
                            // comparing never means scrolling down.
                            if phase == .enrich {
                                EnrichmentCard(
                                    movie: movie,
                                    draft: $draft,
                                    isLocked: false,
                                    showsWatchedWhere: false,
                                    onOkay: { startComparisons() },
                                    activeRow: $enrichRow
                                )
                                .id("enrich")
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                            }

                            if phase == .comparing, let session, !session.isComplete {
                                comparisonCard(session)
                                    .id("compare")
                                    .transition(.move(edge: .bottom).combined(with: .opacity))
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 40)
                    // Keep the rank cards card-shaped and centred on iPad
                    // instead of stretching across the full screen.
                    .nativeContentWidth(560)
                }
                .onChange(of: phase) { _, newPhase in
                    withAnimation(.snappy) {
                        if newPhase == .enrich { proxy.scrollTo("enrich", anchor: .bottom) }
                        if newPhase == .comparing { proxy.scrollTo("compare", anchor: .bottom) }
                        // Center it — anchoring .bottom shoved the Share/Done
                        // buttons down onto the (still-visible) tab bar.
                        if newPhase == .result { proxy.scrollTo("result", anchor: .center) }
                    }
                }
            }
        }
        // Result page leaves via the explicit "Done" button under Share — no
        // floating X up top.
        .presentationBackground(.clear)
        .animation(.snappy(duration: 0.25), value: phase)
        .alert("Discard this ranking?", isPresented: $showDiscardConfirm) {
            Button("Discard", role: .destructive) { cancel() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text("Your comparisons so far won't be saved.")
        }
        // Editors draw as an overlay INSIDE the flow — sheets presented
        // from a clear-background fullScreenCover silently fail to appear
        // on device, so presentation is avoided entirely.
        .overlay {
            if let row = enrichRow {
                EnrichmentEditorOverlay(row: row, draft: $draft, cast: movieCast) {
                    enrichRow = nil
                }
            }
        }
        // Slide the editor in/out instead of popping — the abrupt appearance is
        // what read as choppy.
        .animation(.snappy(duration: 0.28), value: enrichRow)
        // The flow is a clear cover over the app, so milestone confetti needs
        // its own overlay here to land over the result ticket.
        .overlay { CelebrationOverlay() }
        .task {
            movieCast = (try? await TMDBService.shared.cast(for: movie.tmdbID)) ?? []
        }
        .task {
            // For a show, learn its latest aired episode so "I'm all caught up"
            // records the right spot in Currently Watching.
            if movie.mediaKind == "tv" {
                showInfo = try? await TMDBService.shared.extendedDetails(for: movie.tmdbID)
                // Now that we know the real season/episode counts, pull any
                // out-of-range stepper values (set against the fallback caps) in.
                clampProgressToShow()
            }
        }
    }

    /// Abandoning mid-flow: restore the pre-session list locally (a re-rank
    /// already removed the entry — offline, a bare resync can't bring it
    /// back), then reconcile with the server.
    private func cancel() {
        if scored == nil && sentiment != nil {
            Task { await store.abandonSession() }
        }
        dismiss()
    }

    // MARK: Card 1 — title

    private var titleCard: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(Theme.serif(24))
                Text([movie.releaseYear.map(String.init),
                      movie.genres.prefix(2).joined(separator: ", ")]
                    .compactMap { $0?.isEmpty == false ? $0 : nil }
                    .joined(separator: " | "))
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Button {
                // Mid-comparison, closing throws away real work — confirm it.
                if phase == .comparing { showDiscardConfirm = true } else { cancel() }
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
    }

    // MARK: Card 2 — media type

    private var categoryCard: some View {
        // Ranking, not bookmarking — the one choice here is the media type
        // (Movies vs TV Shows), which decides where the rank files.
        HStack(spacing: 10) {
            Text("Add to my list of")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
            Menu {
                ForEach(MediaCategory.allCases) { option in
                    Button {
                        category = option
                    } label: {
                        Label(option.title, systemImage: option.icon)
                    }
                }
            } label: {
                chipLabel(icon: category.icon, title: category.title)
            }
            // The override is applied once when comparisons start — changing it
            // later would only relabel the chip while the rank files under the
            // original kind, so lock it like the sentiment circles.
            .disabled(phase == .comparing || phase == .result)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .floatingCard()
    }

    // MARK: Not out yet — rank is blocked until release; offer Want to Watch.

    private var notReleasedCard: some View {
        let onWatchlist = store.isOnWatchlist(movie.tmdbID)
        return VStack(spacing: 14) {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.largeTitle)
                .foregroundStyle(Theme.gold)
            Text("Not out yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.ink)
            Text("\(movie.releaseWhenText) — you can rank it once it's out.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            PillButton(title: onWatchlist ? "On your Want to Watch list ✓" : "Add to Want to Watch",
                       systemImage: "bookmark") {
                if !onWatchlist { Task { await store.toggleWatchlist(movie: movie) } }
                dismiss()
            }
            Button("Close") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .floatingCard()
    }

    private func chipLabel(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.subheadline)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.bold))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink.opacity(0.7), lineWidth: 1.3))
    }

    // MARK: Card 3 — sentiment circles

    private var sentimentCard: some View {
        VStack(spacing: 14) {
            Text("How was it?")
                .font(.title3.weight(.bold))
            HStack(alignment: .top, spacing: 0) {
                sentimentCircle("I liked it!", color: Theme.sentimentLoved, value: .loved)
                sentimentCircle("It was fine", color: Theme.sentimentFine, value: .fine)
                sentimentCircle("I didn't like it", color: Theme.sentimentDisliked, value: .disliked)
            }
        }
        .padding(.vertical, 16)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .floatingCard()
    }

    private func sentimentCircle(_ label: String, color: Color, value: Sentiment) -> some View {
        let isSelected = sentiment == value
        let isDimmed = sentiment != nil && !isSelected
        return Button {
            pick(value)
        } label: {
            VStack(spacing: 9) {
                Circle()
                    .fill(color.opacity(isDimmed ? 0.45 : 1))
                    .frame(width: 62, height: 62)
                    .overlay {
                        if isSelected {
                            Image(systemName: "checkmark")
                                .font(.title2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .scaleEffect(isSelected ? 1.06 : 1)
                Text(label)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isDimmed ? Theme.gray : Theme.ink)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(phase == .comparing || phase == .result)
    }

    // MARK: "I'm still watching it" (TV) — set progress instead of ranking

    /// True once we know the series has finished airing (Ended/Canceled). If we
    /// don't know yet (details still loading), assume ongoing so we don't hide
    /// "all caught up" from a returning show.
    private var showHasEnded: Bool {
        guard let status = showInfo?.status else { return false }
        return status == "Ended" || status == "Canceled"
    }

    // Bound the steppers to the show's real structure so you can't pick a season
    // or episode that doesn't exist. Generous caps until the show's details load.
    private var seasonMax: Int { max(1, showInfo?.numberOfSeasons ?? 50) }
    private func episodesInSeason(_ season: Int) -> Int {
        max(1, showInfo?.seasonEpisodeCounts[season] ?? 200)
    }
    /// Pull the stepper values back in range when the show's details load or the
    /// season changes (a later season may have fewer episodes).
    private func clampProgressToShow() {
        if swSeason > seasonMax { swSeason = seasonMax }
        let maxEp = episodesInSeason(swSeason)
        if swEpisode > maxEp { swEpisode = maxEp }
    }

    private var stillWatchingCard: some View {
        VStack(spacing: 12) {
            Button {
                withAnimation(.snappy) { showStillWatching.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "tv")
                    Text("I'm still watching it").font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: showStillWatching ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)

            if showStillWatching {
                VStack(spacing: 12) {
                    Text("Where are you?")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    progressStepper("Season", value: $swSeason, min: 1, max: seasonMax)
                    progressStepper("Episode", value: $swEpisode, min: 1, max: episodesInSeason(swSeason))
                    Button {
                        saveStillWatching(caughtUp: false)
                    } label: {
                        Text("Add to Currently Watching")
                            .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                            .frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(Theme.velvet))
                    }
                    .buttonStyle(.plain)
                    // "All caught up" = current on everything aired, waiting on
                    // the next episode — only meaningful for an ONGOING show. On
                    // an ended series, caught up means finished, so you'd rank it,
                    // not mark it still-watching. Hide it for ended shows.
                    if !showHasEnded {
                        Button {
                            saveStillWatching(caughtUp: true)
                        } label: {
                            Label("I'm all caught up", systemImage: "checkmark.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.marquee)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .floatingCard()
        // A later season may have fewer episodes — pull Episode back in range.
        .onChange(of: swSeason) { _, _ in clampProgressToShow() }
    }

    /// A compact +/- stepper (mirrors the Currently-Watching control).
    private func progressStepper(_ label: String, value: Binding<Int>, min: Int, max: Int) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.ink)
            Spacer()
            Button { if value.wrappedValue > min { value.wrappedValue -= 1 } } label: {
                Image(systemName: "minus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(value.wrappedValue > min ? Theme.marquee : Theme.gray.opacity(0.4))
            .accessibilityLabel("Decrease \(label)")
            Text("\(value.wrappedValue)")
                .font(.subheadline.weight(.bold)).monospacedDigit().frame(minWidth: 28)
            Button { if value.wrappedValue < max { value.wrappedValue += 1 } } label: {
                Image(systemName: "plus.circle.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(value.wrappedValue < max ? Theme.marquee : Theme.gray.opacity(0.4))
            .accessibilityLabel("Increase \(label)")
        }
        .font(.title3)
    }

    /// Mark the show as currently watching at the chosen spot and close —
    /// reuses the same RPC + cache reconciliation as the Currently-Watching card.
    /// `caughtUp` flags that they're current on everything aired (waiting on the
    /// next episode), which lets friends see the "all caught up" beat.
    private func saveStillWatching(caughtUp: Bool) {
        Haptics.success()
        // "All caught up" records the latest aired episode so Currently Watching
        // shows where you actually are (not the default S1·E1); the explicit
        // "Add to Currently Watching" uses the stepper position you set.
        let s = caughtUp ? (showInfo?.lastAiredSeason ?? swSeason) : swSeason
        let e = caughtUp ? (showInfo?.lastAiredEpisode ?? swEpisode) : swEpisode
        Task {
            do {
                try await SupabaseService.shared.cacheMovie(movie)   // FK needs the show cached
                try await SupabaseService.shared.setShowProgress(showID: movie.tmdbID,
                                                                 season: s, episode: e,
                                                                 caughtUp: caughtUp)
                store.watchlistSuperseded(movieID: movie.tmdbID)
                ToastCenter.shared.show(caughtUp ? "All caught up 📺" : "Added to Currently Watching 📺")
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
        dismiss()
    }

    private func pick(_ value: Sentiment) {
        guard phase == .sentiment || phase == .enrich else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        sentiment = value
        withAnimation(.snappy) { phase = .enrich }
    }

    // MARK: Step 4 → 5: Okay starts the comparisons

    private func startComparisons() {
        guard let sentiment, phase == .enrich else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // The category chip is a real override, not decoration — a fixed
        // TMDB mislabel (TV movie, miniseries) files where the user said.
        var effective = movie
        effective.mediaKind = category.mediaKind
        store.overrideMediaKind(effective.tmdbID, kind: effective.mediaKind)
        let newSession = store.beginSession(movie: effective, sentiment: sentiment)
        session = newSession
        if newSession.isComplete {
            commit(newSession)      // first movie ever / first in bucket
        } else {
            withAnimation(.snappy) { phase = .comparing }
        }
    }

    // MARK: Card 5 — comparison

    private func comparisonCard(_ current: InsertionSession<Int>) -> some View {
        VStack(spacing: 18) {
            Text("Which do you prefer?")
                .font(.title3.weight(.bold))

            // A finite, advancing bar so it's clear how close the comparisons
            // are to done — otherwise repeated questions feel open-ended.
            ProgressView(value: current.progress)
                .tint(Theme.marquee)
                .frame(maxWidth: 180)
                .animation(.snappy, value: current.progress)

            if let opponentID = current.currentOpponent {
                HStack(spacing: 0) {
                    comparisonOption(
                        title: movie.title,
                        subtitle: movie.releaseYear.map(String.init) ?? "",
                        score: nil
                    ) { choose(.preferNew) }

                    ZStack {
                        Circle().fill(Theme.marquee).frame(width: 44, height: 44)
                        Text("OR").font(.caption.weight(.heavy)).foregroundStyle(Theme.onMarquee)
                    }
                    .zIndex(1)
                    .padding(.horizontal, -16)

                    comparisonOption(
                        title: store.movie(opponentID)?.title ?? "—",
                        subtitle: store.movie(opponentID)?.releaseYear.map(String.init) ?? "",
                        score: store.scoredItem(for: opponentID)?.score
                    ) { choose(.preferExisting) }
                }
                .id(pairID)
                .transition(.opacity)
                // Lock the pair while the previous pick is still animating in,
                // so a quick second tap can't land on the wrong comparison.
                .disabled(choosing)
            }

            HStack {
                Button {
                    if current.canUndo {
                        withAnimation(.snappy(duration: 0.2)) {
                            session?.undo()
                            pairID += 1
                        }
                    } else {
                        // First comparison — nothing to undo yet, so step back to
                        // the details screen (sentiment / notes / Start ranking)
                        // instead of dead-ending. Drop the in-memory session so
                        // re-tapping "Start ranking" begins a fresh placement.
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        withAnimation(.snappy) {
                            session = nil
                            phase = .enrich
                        }
                    }
                } label: {
                    Label("Undo", systemImage: "arrowshape.turn.up.backward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }

                Spacer()

                Button { choose(.tooToughToCall) } label: {
                    Text("Too tough")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 9)
                        .overlay(Capsule().strokeBorder(Theme.marquee, lineWidth: 1.4))
                }

                Spacer()

                Button { choose(.skip) } label: {
                    Label("Skip", systemImage: "arrowshape.turn.up.forward.fill")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 6)
            // Dim + lock the utility row while a pick advances, so it visibly
            // reads as "hang on" instead of silently swallowing a tap.
            .disabled(choosing)
            .opacity(choosing ? 0.5 : 1)
            .animation(.snappy(duration: 0.15), value: choosing)
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .floatingCard()
    }

    private func comparisonOption(title: String, subtitle: String, score: Double?,
                                  action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(Theme.serif(19))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: 5) {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    if let score {
                        Text("·").foregroundStyle(Theme.gray)
                        Text(score.formatted(.number.precision(.fractionLength(1))))
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.scoreColor(score))
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 170)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(Theme.marquee.opacity(0.8), lineWidth: 1.4)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(ComparisonCardStyle())
    }

    private func choose(_ choice: ComparisonChoice) {
        // Block a second tap landing on the same comparison before it advances.
        guard !choosing, var current = session else { return }
        choosing = true
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.snappy(duration: 0.18)) {
            current.choose(choice)
            session = current
            pairID += 1
        }
        if current.isComplete {
            // The last comparison lands with extra weight — you just placed it.
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            commit(current)
        }
        Task { try? await Task.sleep(for: .milliseconds(200)); choosing = false }
    }

    private func commit(_ finished: InsertionSession<Int>) {
        // A commit can take longer than the 200ms comparison tap-guard, and
        // startComparisons() can call this directly — guard against a double save.
        guard !committing else { return }
        committing = true
        Task {
            // Show the result ticket the instant the local score is known
            // (onLocalScored), so the screen no longer waits on the rank_insert
            // round-trip — that write now overlaps the reveal's ~1s "calculating"
            // beat. The score itself stays hidden until the server confirms.
            let result = await store.commit(
                finished, watchDate: draft.watchDate, stealth: draft.stealthMode,
                onLocalScored: { localScored in
                    priorStreak = appSession.profile?.streakWeeks ?? 0
                    withAnimation(.snappy) {
                        session = nil
                        scored = localScored
                        phase = .result
                    }
                })
            // nil = the rank didn't reach the server (store already reverted and
            // toasted). Leave without ever revealing a score for a failed save.
            guard result != nil else {
                committing = false
                dismiss()
                return
            }
            // The server confirmed — reveal NOW. Gating the reveal on the
            // profile refresh let one slow/unbounded request strand the user
            // on "Saving…" (and cost them the notes/date sitting in the
            // draft). The streak refresh runs concurrently, best-effort: a
            // milestone celebration may very occasionally read the prior
            // value, which beats a hung reveal every time.
            commitConfirmed = true
            maybeRevealScore()
            let streakRefresh = Task { await appSession.loadProfile() }
            await persistDraft()
            await streakRefresh.value
            // Insurance: if a future change re-shows the comparison card instead
            // of dismissing, don't leave commit permanently locked.
            committing = false
        }
    }

    /// Save everything from the details card now that the rank exists.
    private func persistDraft() async {
        let supabase = SupabaseService.shared
        var anySaveFailed = false
        // Stealth is handled atomically inside rank_insert (it simply never
        // emits the 'ranked' feed event), so there's no public window to close
        // here and no separate hide step that could fail.
        if !draft.notes.isEmpty {
            do {
                try await supabase.upsertNote(movieID: movie.tmdbID, body: draft.notes,
                                              isPrivate: false,
                                              containsSpoilers: draft.notesContainSpoilers)
            } catch { anySaveFailed = true }
        }
        // Every rank is a watch — the diary gets a row even without a date.
        do {
            try await supabase.logWatch(movieID: movie.tmdbID,
                                        on: draft.watchDate ?? .now,
                                        where: draft.watchedWhere)
        } catch { anySaveFailed = true }
        if !draft.cast.isEmpty {
            do {
                try await supabase.addPerformances(movieID: movie.tmdbID,
                                                   cast: Array(draft.cast))
            } catch { anySaveFailed = true }
        }
        if !draft.watchedWith.isEmpty || draft.watchDate != nil || draft.watchedWhere != nil {
            do {
                try await supabase.updateRanking(movieID: movie.tmdbID,
                                                 watchedWith: Array(draft.watchedWith),
                                                 watchDate: draft.watchDate,
                                                 watchedWhere: draft.watchedWhere)
            } catch { anySaveFailed = true }
            // Tag frequencies just changed — keep the chip order current.
            FriendsCache.shared.warm()
        }
        if anySaveFailed {
            // The rank itself landed; only extras missed. Be specific.
            ToastCenter.shared.show("Some details didn't save — add them from the movie page.")
        }
    }

    // MARK: Card 6 — result

    private func resultCard(_ scored: ScoredItem<Int>) -> some View {
        let profile = appSession.profile
        let name = (profile?.displayName.isEmpty == false ? profile!.displayName : (profile?.username ?? ""))
        let ticketName = firstName(profile?.displayName, profile?.username) ?? name
        return VStack(spacing: 14) {
            RankTicket(
                movie: movie,
                rank: scored.rank,
                name: ticketName,
                handle: profile?.username ?? "",
                streakWeeks: profile?.streakWeeks ?? 0,
                poster: { PosterView(url: movie.posterURL, width: 150) },
                avatar: { AvatarView(url: profile?.avatarURL, size: 38, name: name) },
                score: {
                    if scoreRevealed {
                        ScoreBadge(score: scored.score, size: 64)
                            .overlay { ScoreRevealRing(size: 64) }
                            // A 9+ earns the full marquee treatment.
                            .overlay { if scored.score >= 9.0 { MarqueeBulbRing(diameter: 96) } }
                            .transition(.scale(scale: 0.4).combined(with: .opacity))
                    } else {
                        // Calculates on its own, then springs in — no tap.
                        ScoreRevealPlaceholder(size: 64)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: Theme.cardShadow, radius: 18, y: 8)

            // Actions arrive with the score, not before — the reveal is the
            // moment; sharing is the reward. Two stacked CTAs: Share (primary),
            // then Done to leave.
            if scoreRevealed {
                VStack(spacing: 12) {
                    // A new #1 is the most brag-worthy moment — call it out so
                    // sharing feels like planting a flag, not filing a record.
                    let isTop = scored.rank == 1
                    if let shareImage {
                        ShareLink(
                            item: shareImage,
                            preview: SharePreview(isTop
                                ? "\(movie.title) — my new #1 on Cini"
                                : "\(movie.title) — ranked #\(scored.rank) on Cini",
                                                  image: shareImage)
                        ) { shareLabel(isTop ? "Share your new #1" : "Share") }
                        .buttonStyle(.plain)
                    } else {
                        // Card image didn't render — share text so the button
                        // is never silently missing.
                        ShareLink(item: isTop
                            ? "\(movie.title) is my new #1 on Cini 🎬\n\(AppLinks.titleLink(movie.tmdbID))"
                            : "\(movie.title) — ranked #\(scored.rank) on Cini 🎬\n\(AppLinks.titleLink(movie.tmdbID))") {
                            shareLabel(isTop ? "Share your new #1" : "Share")
                        }
                        .buttonStyle(.plain)
                    }

                    // Hit a round-number milestone? Offer the bigger brag — a
                    // shareable top-5 card — as a distinct, softer celebratory CTA.
                    if let milestone = milestoneJustHit {
                        Button { showTop5Share = true } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "rosette")
                                Text("\(milestone) ranked! Share your top 5")
                            }
                            .font(.headline)
                            .foregroundStyle(Theme.marquee)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(
                                Capsule().fill(Theme.marqueeSoft)
                                    .overlay(Capsule().strokeBorder(Theme.marquee.opacity(0.5), lineWidth: 1))
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            // Solid fill, not just a hairline outline: the sheet
                            // sits over a clear background, so an outline-only
                            // button read as transparent text on the tab bar.
                            .background(
                                Capsule().fill(Theme.surface)
                                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Done")
                }
                .frame(maxWidth: 300)
                .frame(maxWidth: .infinity)   // center the capsules
                .padding(.bottom, 12)
                .transition(.opacity)
            } else if saveSlow {
                // A slow/unstable connection: tell them it's saving so the
                // calculating screen never reads as frozen. It resolves on its
                // own — the score springs in once saved, or the flow bails with
                // an error toast if the write ultimately fails.
                HStack(spacing: 8) {
                    ProgressView().tint(Theme.gray)
                    Text("Saving your rank — hang tight on this connection…")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, 6)
                .transition(.opacity)
            }
        }
        .animation(.snappy, value: saveSlow)
        .sheet(isPresented: $showTop5Share) {
            let profile = appSession.profile
            TopFiveShareSheet(
                name: firstName(profile?.displayName, profile?.username) ?? "",
                handle: profile?.username ?? "",
                avatarURL: profile?.avatarURL,
                movieEntries: topEntries("movie"),
                showEntries: topEntries("tv"))
        }
        .onAppear { scheduleReveal() }
        .task { await prepareShareCard(scored) }
        .task {
            // If the score still hasn't revealed after a beat, the save is slow —
            // surface the "Saving…" note (cleared implicitly once revealed/dismissed).
            try? await Task.sleep(for: .milliseconds(2500))
            if !scoreRevealed { saveSlow = true }
        }
    }

    /// The viewer's top-ranked entries for one kind ("movie"/"tv"), best first,
    /// for the milestone top-5 share card — pulled from the shared ranking store.
    private func topEntries(_ kind: String) -> [TopFiveShareSheet.Entry] {
        let top = (store.lists[kind]?.scoredItems ?? [])
            .sorted { $0.rank < $1.rank }
            .prefix(5)
        return top.compactMap { item in
            guard let m = store.movie(item.id) else { return nil }
            return TopFiveShareSheet.Entry(movie: m, rank: item.rank, score: item.score)
        }
    }

    private func shareLabel(_ title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "square.and.arrow.up")
            Text(title)
        }
        .font(.headline)
        .foregroundStyle(Theme.onMarquee)        // dark text on gold = high contrast
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(Capsule().fill(Theme.marquee))
    }

    /// Auto-reveal a beat after the ticket lands, so the calculating
    /// animation registers before the score springs in. The beat runs
    /// concurrently with the network write; whichever finishes last unlocks
    /// the reveal via `maybeRevealScore`.
    private func scheduleReveal() {
        guard !didScheduleReveal else { return }
        didScheduleReveal = true
        Task {
            // 450ms: long enough for the calculating flicker to register as
            // a moment, short enough that the number feels instant. (A full
            // second read as lag once users ranked in volume.)
            try? await Task.sleep(for: .milliseconds(450))
            beatElapsed = true
            maybeRevealScore()
        }
    }

    /// Reveal only once the calculating beat has played AND the rank is
    /// confirmed on the server — either event calls this; the second one wins.
    private func maybeRevealScore() {
        guard beatElapsed, commitConfirmed else { return }
        revealScore()
    }

    private func revealScore() {
        guard !scoreRevealed else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.5, dampingFraction: 0.62)) {
            scoreRevealed = true
        }
        celebrateIfMilestone()
    }

    /// The rank has committed, so the store's total and the reloaded streak are
    /// current. A round-number milestone wins over a streak bump; either way we
    /// wait a beat so the score's own ripple lands first, then the big payoff.
    private func celebrateIfMilestone() {
        let count = store.watchedCount
        let newStreak = appSession.profile?.streakWeeks ?? 0

        // Pick a celebration: the very first rank is its own milestone moment,
        // then ranked-count milestones, then a streak bump.
        let celebration: Celebration?
        if count == 1 {
            celebration = .firstRank
        } else if CelebrationCenter.rankMilestones.contains(count) {
            celebration = .rankMilestone(count)
            // A round-number milestone is the moment to nudge a top-5 share.
            milestoneJustHit = count
        } else if newStreak >= 2 && newStreak > priorStreak {
            celebration = .streak(newStreak)
        } else {
            celebration = nil
        }

        // When to attempt the App Store review prompt: once you've rated enough
        // to have an opinion worth asking about (10+), or you just hit a
        // celebration moment. Importers can jump past an exact milestone, so we
        // don't require landing on 10 on the nose. The very first rank is a
        // delight beat but FAR too early to ask for a review, so it's excluded.
        // Each call only *attempts* — ReviewPrompt's 3-per-year, 90-days-apart
        // budget decides if it shows, so this never nags.
        let reviewWorthy = count >= 10 || (celebration != nil && count != 1)

        guard celebration != nil || reviewWorthy else { return }
        Task {
            if let celebration {
                try? await Task.sleep(for: .milliseconds(700))
                CelebrationCenter.shared.fire(celebration)
            }
            if reviewWorthy {
                // Let any confetti play first, then ask at the emotional peak.
                try? await Task.sleep(for: .milliseconds(celebration != nil ? 1900 : 900))
                ReviewPrompt.askAfterDelight()
            }
        }
    }

    /// Render the share ticket once the result shows — poster fetched
    /// up front because ImageRenderer won't wait for async images.
    @MainActor
    private func prepareShareCard(_ scored: ScoredItem<Int>) async {
        guard shareImage == nil else { return }
        let profile = appSession.profile
        // Pull both through the shared image cache, concurrently — the poster
        // was just shown on the result ticket so it's a memory-cache hit, and
        // this no longer re-downloads it (or the avatar) over the network.
        let posterURL = movie.posterURL
        let avatarURL = profile?.avatarURL
        async let posterTask: UIImage? = { () async -> UIImage? in
            guard let posterURL else { return nil }
            return await ImageLoader.shared.image(for: posterURL)
        }()
        async let avatarTask: UIImage? = { () async -> UIImage? in
            guard let avatarURL else { return nil }
            return await ImageLoader.shared.image(for: avatarURL)
        }()
        let poster = await posterTask
        let avatar = await avatarTask
        let name = firstName(profile?.displayName, profile?.username) ?? ""
        let card = RankShareCard(movie: movie, scored: scored, poster: poster,
                                 name: name, handle: profile?.username ?? "",
                                 avatar: avatar, streakWeeks: profile?.streakWeeks ?? 0)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3
        if let rendered = renderer.uiImage {
            shareImage = Image(uiImage: rendered)
        }
    }
}

struct Line: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.width, y: rect.midY))
        return path
    }
}

struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}

struct ComparisonCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(configuration.isPressed ? Theme.marqueeSoft : .clear)
            )
            .animation(.snappy(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Shared poster

struct PosterView: View {
    let url: URL?
    var width: CGFloat

    var body: some View {
        CachedAsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle().fill(Theme.gray.opacity(0.18))
                .overlay(Image(systemName: "film").font(.title2).foregroundStyle(Theme.gray))
        }
        .frame(width: width, height: width * 1.5)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: Theme.cardShadow, radius: 8, y: 4)
    }
}
