import SwiftUI

/// The daily hook: one personalized "watch this tonight" pinned to the top of
/// the feed. The pick comes from the `tonight_pick` RPC (highest-predicted
/// Want-to-Watch title, else a friend-loved rec). Tapping opens the movie
/// (where "Where to watch" lives); the standard (+)/bookmark ride the corner.
struct TonightPickCard: View {
    let movie: Movie
    var reason: String?
    var service: String?               // streaming service it's on, e.g. "Netflix"
    var onOpen: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }
    var onDismiss: (() -> Void)?

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
                    if let service {
                        Text("ON \(service.uppercased())")
                            .font(.system(size: 10, weight: .heavy)).tracking(0.5)
                            .foregroundStyle(Theme.background)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Capsule().fill(.white.opacity(0.92)))
                    }
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
            // Not feeling it tonight — dismiss for now.
            .overlay(alignment: .topTrailing) {
                if let onDismiss {
                    Button {
                        Haptics.tap()
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(7)
                            .background(Circle().fill(.black.opacity(0.45)))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel("Not tonight")
                }
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

/// One streamable Tonight's Pick candidate.
struct TonightCardItem: Identifiable, Equatable {
    let movie: Movie
    let reason: String
    let service: String?
    var id: Int { movie.tmdbID }
}

/// Up to three Tonight's Picks stacked like a deck — swipe the top one away
/// (or tap ✕) to reveal the next.
struct TonightStack: View {
    let items: [TonightCardItem]
    var onOpen: (Movie) -> Void = { _ in }
    var onRank: (Movie) -> Void = { _ in }
    /// Reported up so the feed can persist the dismissal (so it stays gone).
    var onDismiss: (Int) -> Void = { _ in }

    @State private var drag: CGSize = .zero

    var body: some View {
        let cards = Array(items.prefix(3))
        if !cards.isEmpty {
            ZStack {
                ForEach(Array(cards.enumerated()).reversed(), id: \.element.id) { pair in
                    let idx = pair.offset
                    let item = pair.element
                    TonightPickCard(
                        movie: item.movie, reason: item.reason, service: item.service,
                        onOpen: onOpen, onQuickAdd: onRank,
                        onDismiss: idx == 0 ? { dismissTop(item) } : nil
                    )
                    .scaleEffect(1 - CGFloat(idx) * 0.04)
                    .offset(y: CGFloat(idx) * 10)
                    .offset(idx == 0 ? drag : .zero)
                    .rotationEffect(.degrees(idx == 0 ? Double(drag.width / 22) : 0))
                    .zIndex(Double(cards.count - idx))
                    .gesture(idx == 0 ? swipe(item) : nil)
                    .animation(.snappy, value: drag)
                    .animation(.snappy, value: items.count)
                }
            }
            // Reserve the card height plus the stack's peek offset.
            .frame(height: 240)
            // Whenever the deck changes (a card dismissed), make sure the new
            // top card isn't left carrying the previous card's drag offset.
            .onChange(of: items.count) { _, _ in drag = .zero }
        }
    }

    private func swipe(_ item: TonightCardItem) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                if abs(value.translation.width) > 90 {
                    Haptics.tap()
                    withAnimation(.snappy) {
                        drag = CGSize(width: value.translation.width > 0 ? 700 : -700,
                                      height: value.translation.height)
                    }
                    Task {
                        try? await Task.sleep(for: .milliseconds(160))
                        dismissTop(item)
                    }
                } else {
                    withAnimation(.snappy) { drag = .zero }
                }
            }
    }

    private func dismissTop(_ item: TonightCardItem) {
        drag = .zero
        onDismiss(item.id)   // the feed removes it from `items` and remembers it
    }
}
