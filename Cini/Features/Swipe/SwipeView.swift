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

    @State private var candidates: [YourListsView.RecCandidate] = []
    @State private var loaded = false
    /// Cards is the default delight; Grid is the power view. Persisted so the
    /// choice sticks between visits.
    @AppStorage("swipe.gridMode") private var gridMode = false
    @State private var suggestTV = false
    @State private var dismissed: Set<Int> = []
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var watchedCountAtRank = 0
    @Namespace private var posterZoom

    /// The current pool minus dismissed / already-watched, filtered to the
    /// selected media kind.
    private var visible: [YourListsView.RecCandidate] {
        candidates.filter {
            !dismissed.contains($0.movie.tmdbID)
                && !store.isWatched($0.movie.tmdbID)
                && (suggestTV ? $0.movie.mediaKind == "tv" : $0.movie.mediaKind != "tv")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .screenHPadding()
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Theme.background)
                content
            }
            .nativeContentWidth()
            .background(Theme.background)
            .fullScreenCover(item: $logMovie, onDismiss: {
                // Ranked one → it's now Watched; confirm and it drops from the deck.
                if store.watchedCount > watchedCountAtRank {
                    ToastCenter.shared.show("Added to your Watched list 🎬")
                }
            }) { movie in
                LogFlowView(movie: movie)
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
                    .zoomDestination(id: movie.tmdbID, in: posterZoom)
            }
            .task { await load() }
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Swipe").font(Theme.pageHeader)
                Spacer()
                Button {
                    withAnimation(.snappy) { gridMode.toggle() }
                } label: {
                    Image(systemName: gridMode ? "rectangle.stack" : "square.grid.2x2")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .padding(8)
                        .background(Circle().fill(Theme.fill))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(gridMode ? "Show as cards" : "Show as grid")
            }
            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { suggestTV ? 1 : 0 },
                                   set: { suggestTV = $0 == 1 }))
        }
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            Spacer()
            ProgressView()
            Spacer()
        } else if visible.isEmpty {
            emptyState
        } else if gridMode {
            ScrollView {
                SuggestionGrid(
                    movies: visible.map(\.movie),
                    onRank: { watchedCountAtRank = store.watchedCount; logMovie = $0 },
                    onSave: { movie in
                        guard !store.isOnWatchlist(movie.tmdbID) else { return }
                        Task { await store.toggleWatchlist(movie: movie) }
                        ToastCenter.shared.show("Saved to Want to Watch ✓")
                    },
                    onDismiss: { movie in
                        withAnimation(.snappy) { _ = dismissed.insert(movie.tmdbID) }
                    }
                )
                .screenHPadding()
                .padding(.top, 8)
            }
        } else {
            RecCardDeck(
                candidates: visible,
                onOpen: { store.cache($0); detailMovie = $0 },
                onLog: { watchedCountAtRank = store.watchedCount; logMovie = $0 },
                onSave: { m in
                    if !store.isOnWatchlist(m.tmdbID) { Task { await store.toggleWatchlist(movie: m) } }
                },
                onUnsave: { m in
                    if store.isOnWatchlist(m.tmdbID) { Task { await store.toggleWatchlist(movie: m) } }
                },
                onRefresh: { Task { candidates = []; loaded = false; await load() } },
                showRank: true,
                onRank: { watchedCountAtRank = store.watchedCount; logMovie = $0 }
            )
            // Reset the deck's position when switching Movies ↔ TV.
            .id(suggestTV)
            .screenHPadding()
            .padding(.top, 12)
            Spacer(minLength: 0)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.gray)
            Text(suggestTV ? "No shows to swipe right now" : "No movies to swipe right now")
                .font(.subheadline.weight(.bold))
            Text("Rank a few titles so Cini learns your taste — or check the other tab up top.")
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
    }

    private func similarToTop(_ id: Int?) async -> [Movie]? {
        guard let id else { return nil }
        return try? await TMDBService.shared.similar(to: id)
    }
}
