import SwiftUI

/// A first-party "promoted release" card for the feed: a new/upcoming film
/// chosen from the user's OWN taste (their most-ranked genre) — no third-party
/// ad SDK, no IDFA, no cross-app tracking. We do log first-party engagement
/// (impression/open/add, our data only) via `log_featured_event` to measure
/// performance. It reuses the standard artwork quick actions so the
/// (+)/bookmark sit exactly where they do everywhere else.
struct PromotedReleaseCard: View {
    let movie: Movie
    var reason: String?
    var onOpen: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }

    // One impression per card lifetime (onAppear can fire repeatedly).
    @State private var loggedImpression = false

    private var releaseTag: String? {
        if movie.isReleased { return "In theaters now" }
        guard let raw = movie.releaseDateFull, raw.count == 10,
              let date = DateFormatter.posixDay.date(from: raw) else { return "Coming soon" }
        return "In theaters \(date.formatted(.dateTime.month(.abbreviated).day()))"
    }

    var body: some View {
        Button {
            SupabaseService.shared.logFeaturedEvent(movieID: movie.tmdbID, action: "open")
            onOpen(movie)
        } label: {
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
                            .lineLimit(1)
                    }
                }
                .padding(14)
                // Keep text off the (+)/bookmark corner, and legible over a
                // bright backdrop.
                .frame(maxWidth: 210, alignment: .leading)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
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
            ArtworkQuickActions(movie: movie, onLog: { m in
                SupabaseService.shared.logFeaturedEvent(movieID: m.tmdbID, action: "add")
                onQuickAdd(m)
            })
            .padding(12)
        }
        // First-party impression count (our data only — see log_featured_event).
        .onAppear {
            guard !loggedImpression else { return }
            loggedImpression = true
            SupabaseService.shared.logFeaturedEvent(movieID: movie.tmdbID, action: "impression")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Featured release: \(movie.title)")
    }
}
