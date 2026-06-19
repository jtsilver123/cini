import SwiftUI

/// "Movies you may have seen" — popular titles you've probably watched, so you
/// can rank your back-catalog fast: tap a poster to rank, hold to save, ✕ to
/// skip. This lives in the Watched area (Search deep-links into it to stay
/// focused). The leading word toggles Movies ↔ TV shows; a grid/list switch and
/// an import shortcut round it out. The interactive grid is the shared
/// `SuggestionGrid`, so the rank/save/dismiss gestures match everywhere.
struct MaybeSeenView: View {
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    /// Opened from the TV category → start on TV shows.
    var startTV: Bool = false

    @State private var maybeSeen: [Movie] = []
    @State private var dismissed: Set<Int> = []
    @State private var suggestTV = false
    @AppStorage("search.suggestionsGrid") private var grid = true
    @AppStorage("cini.search.importBannerHidden") private var importBannerHidden = false
    @State private var loaded = false
    @State private var showAll = false
    @State private var showImport = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var watchedCountAtRank = 0
    @Namespace private var posterZoom

    private var visible: [Movie] {
        maybeSeen.filter {
            !dismissed.contains($0.tmdbID) && !store.isWatched($0.tmdbID) && matchesToggle($0)
        }
    }

    private func matchesToggle(_ movie: Movie) -> Bool {
        suggestTV ? movie.mediaKind == "tv" : movie.mediaKind != "tv"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack { heading; Spacer(); viewToggle }
                    caption

                    if !importBannerHidden { importBanner }

                    if !loaded {
                        SearchSkeleton(kind: .titles)
                    } else if visible.isEmpty {
                        emptyState
                    } else {
                        let cap = showAll ? 100 : (grid ? 12 : 4)
                        suggestions(Array(visible.prefix(cap)))
                        if visible.count > cap && !showAll {
                            seeAllButton(count: visible.count)
                        }
                    }
                }
                .padding(.vertical, 16)
                .screenHPadding()
            }
            .nativeContentWidth()
            .background(Theme.background)
            .navigationTitle("You may have seen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            .fullScreenCover(item: $logMovie, onDismiss: {
                // Ranked one → it's now in Watched; the card animates out and we
                // confirm where it went.
                if store.watchedCount > watchedCountAtRank {
                    ToastCenter.shared.show("Added to your Watched list 🎬")
                }
            }) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
                    .zoomDestination(id: movie.tmdbID, in: posterZoom)
            }
            .onAppear { suggestTV = startTV }
            .task { await load() }
        }
    }

    // MARK: Pieces (mirrors the old Search section, minus its shared helpers)

    /// "**Movies** you may have seen" — the leading word flips Movies ↔ TV.
    private var heading: some View {
        HStack(spacing: 0) {
            Button {
                withAnimation(.snappy) { suggestTV.toggle() }
            } label: {
                HStack(spacing: 3) {
                    Text(suggestTV ? "TV shows" : "Movies").fontWeight(.heavy)
                    Image(systemName: "arrow.left.arrow.right").font(.caption2.weight(.bold))
                }
                .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            Text(" you may have seen").foregroundStyle(Theme.ink)
        }
        .font(.headline)
    }

    @ViewBuilder
    private var caption: some View {
        if grid {
            Label("Rank what you've already watched — tap a poster to rank, hold to save, ✕ to skip.",
                  systemImage: "hand.tap.fill")
                .font(.caption)
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 2)
        } else {
            Text("Rank what you've already watched.")
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
    }

    private var viewToggle: some View {
        Button {
            withAnimation(.snappy) { grid.toggle() }
        } label: {
            Image(systemName: grid ? "list.bullet" : "square.grid.2x2")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .padding(6)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(grid ? "Show as list" : "Show as grid")
    }

    @ViewBuilder
    private func suggestions(_ list: [Movie]) -> some View {
        if grid {
            SuggestionGrid(
                movies: list,
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
            .padding(.top, 4)
        } else {
            ForEach(list) { movie in
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { watchedCountAtRank = store.watchedCount; logMovie = movie },
                    onOpen: { detailMovie = movie },
                    onDismiss: { dismissed.insert(movie.tmdbID) },
                    zoomNamespace: posterZoom
                )
                Divider()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.title).foregroundStyle(Theme.gray)
            Text(suggestTV ? "You've ranked these shows" : "You've ranked these movies")
                .font(.subheadline.weight(.semibold))
            Text("Switch between Movies and TV shows up top, or search for anything else you've seen.")
                .font(.caption).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    /// Import prompt with the source logos and an X to dismiss for good.
    private var importBanner: some View {
        Button {
            showImport = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3)
                    .foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Import your history")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Bring your ratings from Letterboxd, IMDb, or Netflix")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    ImportSourceLogos().padding(.top, 3)
                }
                Spacer(minLength: 18)   // leave room for the X
            }
            .padding(14)
        }
        .buttonStyle(.plain)
        .floatingCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap()
                withAnimation { importBannerHidden = true }
                ToastCenter.shared.show("You can import anytime from your profile menu")
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
        .padding(.vertical, 6)
    }

    private func seeAllButton(count: Int) -> some View {
        Button {
            withAnimation { showAll = true }
        } label: {
            HStack {
                Text("See All (\(count))").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down")
            }
            .foregroundStyle(Theme.marquee)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func load() async {
        guard maybeSeen.isEmpty else { return }
        maybeSeen = (try? await TMDBService.shared.popular()) ?? []
        for movie in maybeSeen { store.cache(movie) }
        loaded = true
    }
}
