import SwiftUI

/// The daily hook: one personalized "watch this tonight" pinned to the top of
/// the feed. The pick comes from the `tonight_pick` RPC (highest-predicted
/// Want-to-Watch title, else a friend-loved rec). Tapping opens the movie
/// (where "Where to watch" lives); the standard (+)/bookmark ride the corner.
struct TonightPickCard: View {
    let movie: Movie
    var reason: String?
    var onOpen: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }

    var body: some View {
        Button {
            onOpen(movie)
        } label: {
            ZStack(alignment: .bottomLeading) {
                CachedAsyncImage(url: movie.backdropURL ?? movie.posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Theme.surface
                }
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()

                LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.88)],
                               startPoint: .top, endPoint: .bottom)

                VStack(alignment: .leading, spacing: 4) {
                    Text(movie.title)
                        .font(Theme.serif(24))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let reason {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.88))
                            .lineLimit(2)
                    }
                }
                .padding(14)
                // Keep text clear of the (+)/bookmark corner and legible.
                .frame(maxWidth: 220, alignment: .leading)
                .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
            }
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous))
            // A thin marquee rim so the daily pick reads as the premium,
            // special surface it is.
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .strokeBorder(Theme.marquee.opacity(0.45), lineWidth: 1)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 5) {
                    Image(systemName: "moon.stars.fill")
                    Text("TONIGHT'S PICK").tracking(1.5)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Theme.marquee))
                .padding(12)
            }
        }
        .buttonStyle(.plain)
        // Same scrimmed (+)/bookmark corner as every other piece of artwork.
        .overlay(alignment: .bottomTrailing) {
            ArtworkQuickActions(movie: movie, onLog: { onQuickAdd($0) })
                .padding(12)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's pick: \(movie.title). \(reason ?? "")")
    }
}
