import SwiftUI

/// A first-party "promoted release" card for the feed: a new/upcoming film
/// chosen from the user's OWN taste (their most-ranked genre) — no tracking,
/// no third-party ad SDK, no IDFA. It reuses the standard artwork quick
/// actions so the (+)/bookmark sit exactly where they do everywhere else.
struct PromotedReleaseCard: View {
    let movie: Movie
    var reason: String?
    var onOpen: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }

    private var releaseTag: String? {
        if movie.isReleased { return "In theaters now" }
        guard let raw = movie.releaseDateFull, raw.count == 10,
              let date = DateFormatter.posixDay.date(from: raw) else { return "Coming soon" }
        return "In theaters \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        Button { onOpen(movie) } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: movie.backdropURL ?? movie.posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.surface
                }
                .frame(maxWidth: .infinity)
                .frame(height: 200)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.2), .black.opacity(0.85)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    if let releaseTag {
                        Text(releaseTag)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Theme.marquee)
                    }
                    Text(movie.title)
                        .font(Theme.serif(22))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(14)
                .frame(maxWidth: 200, alignment: .leading)   // leave room for the quick actions
            }
            .frame(height: 200)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(alignment: .topLeading) {
                Text("FEATURED")
                    .font(.caption2.weight(.bold))
                    .tracking(1.5)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.45)))
                    .padding(12)
            }
        }
        .buttonStyle(.plain)
        // Same scrimmed (+)/bookmark corner as every other piece of artwork.
        .overlay(alignment: .bottomTrailing) {
            ArtworkQuickActions(movie: movie, onLog: onQuickAdd)
                .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Featured release: \(movie.title)")
    }
}
