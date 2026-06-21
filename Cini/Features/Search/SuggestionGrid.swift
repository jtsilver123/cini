import SwiftUI

/// CIN-33: a poster grid for ranking titles you may have seen — the same grid
/// used in onboarding. Tap a card to rank it, ✕ to dismiss it, or long-press
/// for Save to Want to Watch. Ranked cards get a stamp until they animate out.
struct SuggestionGrid: View {
    let movies: [Movie]
    var onRank: (Movie) -> Void = { _ in }
    var onSave: (Movie) -> Void = { _ in }
    var onDismiss: (Movie) -> Void = { _ in }
    var posterWidth: CGFloat = 104

    @Environment(RankingStore.self) private var store
    @Environment(\.horizontalSizeClass) private var hSize

    private var columns: [GridItem] {
        // Slightly larger posters on iPad so the grid isn't a field of tiny tiles.
        let minimum = hSize == .regular ? max(posterWidth, 132) : posterWidth
        return [GridItem(.adaptive(minimum: minimum), spacing: 12)]
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(movies) { movie in
                card(movie)
            }
        }
    }

    @ViewBuilder
    private func card(_ movie: Movie) -> some View {
        let ranked = store.isWatched(movie.tmdbID)
        VStack(spacing: 6) {
            // The poster's rank tap is a gesture (NOT a Button) so the bookmark
            // and ✕ can sit on top as their own buttons. Nesting Buttons inside
            // a Button's label breaks hit-testing — taps got swallowed and
            // ranking "glitched out."
            PosterView(url: movie.posterURL, width: posterWidth)
                .overlay { if ranked { rankedStamp } }
                // ✕ to dismiss — top-left.
                .overlay(alignment: .topLeading) {
                    if !ranked {
                        Button { onDismiss(movie) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.55)))
                                .padding(5)
                                // 44pt hit target so a corner tap dismisses
                                // instead of accidentally ranking the title.
                                .frame(width: 44, height: 44, alignment: .topLeading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss \(movie.title)")
                    }
                }
                // Save to Want to Watch — a visible bookmark (top-right).
                .overlay(alignment: .topTrailing) {
                    if !ranked {
                        Button { onSave(movie) } label: {
                            Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : .white)
                                .padding(5)
                                .background(Circle().fill(.black.opacity(0.55)))
                                .padding(5)
                                // 44pt hit target so a corner tap saves
                                // instead of accidentally ranking the title.
                                .frame(width: 44, height: 44, alignment: .topTrailing)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Bookmark \(movie.title) to Want to Watch")
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if !ranked { onRank(movie) } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Rank \(movie.title)")
                // Hold for the "save it instead" path.
                .contextMenu {
                    Button { onRank(movie) } label: { Label("Rank it", systemImage: "star") }
                    Button { onSave(movie) } label: { Label("Bookmark to Want to Watch", systemImage: "bookmark") }
                    Button(role: .destructive) { onDismiss(movie) } label: {
                        Label("Not interested", systemImage: "xmark")
                    }
                }

            Text(movie.title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(ranked ? Theme.scoreGreen : Theme.ink)
                .lineLimit(1)
        }
    }

    private var rankedStamp: some View {
        ZStack {
            Color.black.opacity(0.5)
            VStack(spacing: 4) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.scoreGreen)
                Text("RANKED")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.5)
                    .foregroundStyle(.white)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
