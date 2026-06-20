import SwiftUI

/// The Swipe tab — a Tinder-style way to triage what to watch next. Two
/// presentations of the same personalized pool: a card deck (default) and a
/// grid, toggled top-right. Swipe right (or ♥) saves to Want to Watch, left
/// (or ✕) passes, and the gold + ranks one you've already seen (the real
/// head-to-head flow). Movies and TV each get their own deck via the toggle.
///
/// Reuses the shared `RecCardDeck` (cards) and `SuggestionGrid` (grid) so the
/// save / pass / rank gestures are identical to everywhere else in the app.
struct SwipeView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter

    @State private var candidates: [YourListsView.RecCandidate] = []
    @State private var loaded = false
    /// Grid (pick from posters — best for ranking things you've watched) or
    /// Cards (the swipe deck — best for finding things to watch). Persisted so
    /// the choice sticks, and auto-selected by the deep link that opened Recs.
    private enum Layout: String, CaseIterable {
        case grid, cards
    }
    @AppStorage("swipe.layout") private var layout: Layout = .cards
    @State private var suggestTV = false
    @State private var dismissed: Set<Int> = []
    @State private var filters = MovieFilters()
    @State private var showFilterSheet = false
    @State private var bookmarkCounts: [Int: Int] = [:]
    @AppStorage("swipe.importBannerHidden") private var importBannerHidden = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var watchedCountAtRank = 0
    /// The title most recently sent into the rank flow — so the post-rank toast
    /// can offer to open its page.
    @State private var lastRanked: Movie?
    @State private var showImport = false
    @Namespace private var posterZoom

    /// The current pool minus dismissed / already-watched, filtered to the
    /// selected media kind.
    private var visible: [YourListsView.RecCandidate] {
        candidates.filter {
            !dismissed.contains($0.movie.tmdbID)
                && !store.isWatched($0.movie.tmdbID)
                && (suggestTV ? $0.movie.mediaKind == "tv" : $0.movie.mediaKind != "tv")
                && filters.passes($0.movie)
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .screenHPadding()
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(Theme.background)
                // Pills sit just outside the screen gutter so they align with
                // the header chrome instead of being double-indented.
                filterPills
                    .padding(.bottom, 6)
                    .background(Theme.background)
                if !importBannerHidden {
                    importBanner
                        .screenHPadding()
                        .padding(.bottom, 4)
                }
                ScrollViewReader { proxy in
                    // The VStack is essential: the cards layout returns the deck
                    // PLUS a Spacer, and a bare multi-view tuple inside a
                    // ScrollViewReader overlaps instead of stacking — which made
                    // the card balloon past the screen edge. The VStack restores
                    // normal vertical stacking for every layout.
                    VStack(spacing: 0) {
                        content
                    }
                    // Re-tapping the Recs tab jumps the grid/list back to the
                    // top (the cards layout has nothing to scroll).
                    .onChange(of: tabRouter.retap[.swipe]) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("recsTop", anchor: .top) }
                    }
                }
            }
            .nativeContentWidth()
            .background(Theme.background)
            .fullScreenCover(item: $logMovie, onDismiss: {
                // Ranked one → it's now Watched; confirm, and offer to open its
                // page. It also drops from the deck (visible filters watched out).
                if store.watchedCount > watchedCountAtRank, let ranked = lastRanked {
                    ToastCenter.shared.showTap("Ranked \(ranked.title) 🎬 · View") {
                        store.cache(ranked)
                        detailMovie = ranked
                    }
                }
            }) { movie in
                LogFlowView(movie: movie)
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
                    .zoomDestination(id: movie.tmdbID, in: posterZoom)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .sheet(isPresented: $showFilterSheet) {
                MovieFilterSheet(
                    filters: $filters,
                    movies: candidates.map(\.movie),
                    sortDescending: .constant(true),
                    sortHighLabel: "", sortLowLabel: "", showSort: false)
                .presentationDetents([.medium, .large])
            }
            .task { await load() }
            // A deep link (e.g. "Movies you may have seen") can ask Recs to
            // preselect Movies or TV — honor it whether the tab is new or alive.
            .onAppear { consumeDeepLink() }
            .onChange(of: tabRouter.pendingRecsTV) { _, _ in consumeDeepLink() }
            .onChange(of: tabRouter.pendingRecsGrid) { _, _ in consumeDeepLink() }
        }
    }

    /// Honor a deep link into Recs: it can preselect the media kind AND the
    /// layout (grid for "things you've watched", cards for "find to watch").
    private func consumeDeepLink() {
        if let wantTV = tabRouter.pendingRecsTV {
            tabRouter.pendingRecsTV = nil
            suggestTV = wantTV
        }
        if let wantGrid = tabRouter.pendingRecsGrid {
            tabRouter.pendingRecsGrid = nil
            withAnimation(.snappy) { layout = wantGrid ? .grid : .cards }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Recs").font(Theme.pageHeader)
                Spacer()
                // Card vs grid is a compact icon toggle up here; the big toggle
                // below is the content split (Movies vs TV).
                compactViewToggle
                importButton
            }
            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { suggestTV ? 1 : 0 },
                                   set: { suggestTV = $0 == 1 }))
        }
    }

    /// Import-your-history button: icon + "Import" label, so it reads as an
    /// action rather than a bare glyph.
    private var importButton: some View {
        Button { showImport = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down")
                Text("Import")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.marquee)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import your history")
    }

    /// Compact card-vs-grid VIEW toggle (icons), top-right of the header. Cards
    /// = the swipe deck (default), grid = the poster grid. The note above each
    /// view spells out what it's for.
    private var compactViewToggle: some View {
        HStack(spacing: 2) {
            compactViewSegment(.cards, icon: "rectangle.stack", label: "Card view")
            compactViewSegment(.grid, icon: "square.grid.2x2", label: "Grid view")
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
        // The product tour points its coachmark at this toggle.
        .tourAnchor("recsToggle")
    }

    private func compactViewSegment(_ option: Layout, icon: String, label: String) -> some View {
        let on = layout == option
        return Button {
            withAnimation(.snappy) { layout = option }
        } label: {
            Image(systemName: icon)
                .font(.footnote.weight(.bold))
                .foregroundStyle(on ? Theme.background : Theme.gray)
                .frame(width: 40, height: 30)
                .background(Capsule().fill(on ? Theme.marquee : .clear))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label)\(on ? ", selected" : "")")
    }

    /// The quick filter pills (with the leading filter icon). Lives OUTSIDE the
    /// header's screen gutter — the bar self-insets, so wrapping it in
    /// screenHPadding too would double-indent the pills. No negative padding:
    /// that makes this greedy horizontal scroll report a width wider than the
    /// screen and shoves the whole view off both edges.
    private var filterPills: some View {
        MovieFilterBar(filters: $filters, movies: candidates.map(\.movie),
                       onFilterTap: { showFilterSheet = true })
    }

    /// Dismissible nudge to bring a full history over — same look as the import
    /// banner elsewhere.
    private var importBanner: some View {
        Button { showImport = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3).foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import your history")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Bring your ratings from Letterboxd, IMDb, or Netflix")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    ImportSourceLogos().padding(.top, 2)
                }
                Spacer(minLength: 18)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .floatingCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap()
                withAnimation { importBannerHidden = true }
                ToastCenter.shared.show("You can import anytime from the icon up top")
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.gray)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss import suggestion")
        }
        .padding(.top, 6)
    }

    /// A small instructional note above the grid/deck, adapting to the toggle.
    private func modeNote(_ text: String) -> some View {
        Label(text, systemImage: "hand.tap")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.gray)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Spacer()
            ProgressView()
            Spacer()
        } else if visible.isEmpty {
            emptyState
        } else {
            switch layout {
            case .grid:
                ScrollView {
                    VStack(spacing: 8) {
                        modeNote("Tap a poster to rank a \(suggestTV ? "show" : "movie") you've seen")
                        SuggestionGrid(
                            movies: visible.map(\.movie),
                            onRank: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                            onSave: { movie in
                                guard !store.isOnWatchlist(movie.tmdbID) else { return }
                                Task { await store.toggleWatchlist(movie: movie) }
                                ToastCenter.shared.show("Bookmarked to Want to Watch ✓")
                            },
                            onDismiss: { movie in
                                withAnimation(.snappy) { _ = dismissed.insert(movie.tmdbID) }
                            }
                        )
                    }
                    .screenHPadding()
                    .padding(.top, 8)
                    .id("recsTop")
                }
            case .cards:
                // A small, capped top gap (not a full center) so the deck keeps a
                // steady spot: dismissing the import banner makes the deck rise to
                // fill that space instead of leaving a growing void above it.
                Spacer(minLength: 0).frame(maxHeight: 18)
                modeNote("Swipe right to save · left to skip · + to rank")
                    .padding(.bottom, 4)
                RecCardDeck(
                    candidates: visible,
                    onOpen: { store.cache($0); detailMovie = $0 },
                    onLog: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                    onSave: { m in
                        if !store.isOnWatchlist(m.tmdbID) { Task { await store.toggleWatchlist(movie: m) } }
                    },
                    onUnsave: { m in
                        if store.isOnWatchlist(m.tmdbID) { Task { await store.toggleWatchlist(movie: m) } }
                    },
                    onRefresh: { Task { candidates = []; loaded = false; await load() } },
                    showRank: true,
                    onRank: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                    richDetail: true,
                    bookmarkCounts: bookmarkCounts
                )
                // Reset the deck's position when switching Movies ↔ TV.
                .id(suggestTV)
                // Match the app's standard screen gutter so the deck lines up
                // with the grid/list views and doesn't run to the screen edge.
                .screenHPadding()
                Spacer(minLength: 0)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.gray)
            Text(suggestTV ? "Fresh shows are on the way" : "Fresh picks are on the way")
                .font(.subheadline.weight(.bold))
            Text("Rank a few titles and Cini dials in your taste — your personalized deck shows up right here.")
                .font(.caption).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Build the pool: friends' loved titles → similar to your #1 → trending →
    /// popular. Every source returns both movies and TV, so the toggle has a
    /// full deck either way. Already-watched titles are filtered out in `visible`.
    private func load() async {
        guard candidates.isEmpty else { return }
        let topID = store.watchedItems.first?.id
        async let friendRecsTask = SupabaseService.shared.recsForUser()
        async let trendingTask = TMDBService.shared.trending()
        async let popularTask = TMDBService.shared.popular()
        let similar = await similarToTop(topID)

        var pending: [(id: Int, reason: String)] = []
        var seen = Set<Int>()

        if let friendRecs = try? await friendRecsTask {
            let rows = (try? await SupabaseService.shared.movies(ids: friendRecs.map(\.movieId))) ?? []
            for row in rows { store.cache(row.asMovie) }
            for rec in friendRecs where seen.insert(rec.movieId).inserted {
                let who = rec.topFriendUsername.map { "@\($0)" } ?? "friends"
                pending.append((rec.movieId, rec.friendCount > 1
                    ? "Loved by \(who) + \(rec.friendCount - 1) more"
                    : "Loved by \(who)"))
            }
        }
        if let similar {
            let topTitle = topID.flatMap { store.movie($0)?.title } ?? "your favorite"
            for movie in similar.prefix(12)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Because you liked \(topTitle)"))
            }
        }
        if let trending = try? await trendingTask {
            for movie in trending
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Trending this week"))
            }
        }
        if let popular = try? await popularTask {
            for movie in popular
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Popular right now"))
            }
        }

        candidates = pending.compactMap { candidate in
            store.movie(candidate.id).map {
                YourListsView.RecCandidate(movie: $0, reason: candidate.reason)
            }
        }
        loaded = true

        // How many people have each title bookmarked — social proof on the cards.
        bookmarkCounts = await SupabaseService.shared.watchlistCounts(movieIDs: pending.map(\.id))

        // Fill in runtime, streaming, and a plot summary for the richer cards
        // (and so the genre/streaming filters have something to match) — in the
        // background so the deck shows immediately.
        await enrich(pending.prefix(16).map(\.id))
        candidates = candidates.map {
            YourListsView.RecCandidate(movie: store.movie($0.movie.tmdbID) ?? $0.movie, reason: $0.reason)
        }
    }

    /// At most six detail fetches in flight (polite to TMDB).
    private func enrich(_ ids: [Int]) async {
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            var remaining = ids[...]
            for _ in 0..<min(6, remaining.count) {
                let id = remaining.removeFirst()
                group.addTask { await store.enrich(id) }
            }
            while await group.next() != nil {
                if let id = remaining.popFirst() { group.addTask { await store.enrich(id) } }
            }
        }
    }

    private func similarToTop(_ id: Int?) async -> [Movie]? {
        guard let id else { return nil }
        return try? await TMDBService.shared.similar(to: id)
    }
}
