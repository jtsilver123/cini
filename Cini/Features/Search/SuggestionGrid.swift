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

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: posterWidth), spacing: 12)]
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
            Button { onRank(movie) } label: {
                PosterView(url: movie.posterURL, width: posterWidth)
                    // Save to Want to Watch — a visible bookmark (top-left),
                    // so it isn't hidden behind a long-press.
                    .overlay(alignment: .topLeading) {
                        if !ranked {
                            Button { onSave(movie) } label: {
                                Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : .white)
                                    .padding(5)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .padding(5)
                            .accessibilityLabel("Save \(movie.title) to Want to Watch")
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if !ranked {
                            Button { onDismiss(movie) } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(5)
                                    .background(Circle().fill(.black.opacity(0.55)))
                            }
                            .buttonStyle(.plain)
                            .padding(5)
                            .accessibilityLabel("Dismiss \(movie.title)")
                        }
                    }
                    .overlay { if ranked { rankedStamp } }
            }
            .buttonStyle(.plain)
            .disabled(ranked)
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
