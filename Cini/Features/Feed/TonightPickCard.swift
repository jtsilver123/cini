import SwiftUI

/// The daily hook: one personalized "watch this tonight" pinned to the top of
/// the feed. The pick comes from the `tonight_pick` RPC (highest-predicted
/// Want-to-Watch title, else a friend-loved rec). Tapping opens the movie
/// (where "Where to watch" lives); the standard (+)/bookmark ride the corner.
struct TonightPickCard: View {
    let movie: Movie
    var reason: String?
    var service: String?               // streaming service it's on, e.g. "Netflix"
    var serviceLogo: URL?              // that service's logo (TMDB), shown in the badge
    /// Off for the Recs deck, which reuses this card without the daily badge.
    var showTonightBadge: Bool = true
    /// Card height — taller for the Swipe deck's richer layout.
    var height: CGFloat = 220
    /// A short metadata line (e.g. "2021 · 2h 12m") shown under the title.
    var detail: String? = nil
    /// A short plot summary shown on the Swipe deck's richer card.
    var overview: String? = nil
    /// How many people have bookmarked this title (shown as social proof).
    var savedCount: Int? = nil
    /// The scrimmed (+)/bookmark corner. Off in the swipe deck, where the
    /// control bar below owns those actions.
    var showQuickActions: Bool = true
    /// Live horizontal drag of the top card, so the swipe stamps fade in.
    var dragX: CGFloat = 0
    var onOpen: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }
    var onDismiss: (() -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The container is a flexible Color.clear (it takes exactly the
            // offered width); the image fills it as an overlay. Sizing the image
            // directly with scaledToFill + frame(maxWidth:.infinity) made a 16:9
            // backdrop report ~height×16/9 (~533pt) wide — wider than the screen —
            // which pushed the whole feed/Recs view off the left edge.
            Color.clear
                .overlay {
                    CachedAsyncImage(url: movie.backdropURL ?? movie.posterURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Theme.surface
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .clipped()

            LinearGradient(colors: [.clear, .black.opacity(0.25), .black.opacity(0.88)],
                           startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 4) {
                serviceBadge
                Text(movie.title)
                    .font(Theme.serif(24))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(1)
                }
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                if let overview, !overview.isEmpty {
                    Text(overview)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                }
            }
            .padding(14)
            // Keep text clear of the (+)/bookmark corner and legible.
            .frame(maxWidth: overview == nil ? 220 : 270, alignment: .leading)
            .shadow(color: .black.opacity(0.6), radius: 6, y: 1)
        }
        // Cap the whole card to the offered width — belt-and-suspenders so no
        // child (image/text) can ever make it wider than its container.
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous))
        // A thin marquee rim so the daily pick reads as the premium,
        // special surface it is.
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .strokeBorder(Theme.marquee.opacity(0.45), lineWidth: 1)
        )
        .overlay(alignment: .topLeading) {
            if showTonightBadge {
                HStack(spacing: 5) {
                    Image(systemName: "moon.stars.fill")
                    Text("TONIGHT'S PICK").tracking(1.5)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.background)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(Theme.marquee))
                .padding(12)
            } else if let savedCount, savedCount > 0 {
                // Social proof: how many people have bookmarked this title.
                HStack(spacing: 4) {
                    Image(systemName: "bookmark.fill")
                    Text("\(savedCount.formattedCompact) saved")
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(12)
            }
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
        // Same scrimmed (+)/bookmark corner as every other piece of artwork —
        // unless the host (the swipe deck) owns those actions in its own bar.
        .overlay(alignment: .bottomTrailing) {
            if showQuickActions {
                ArtworkQuickActions(movie: movie, onLog: { onQuickAdd($0) })
                    .padding(12)
            }
        }
        // Tinder-style stamps: drag right to save, left to dismiss.
        .overlay { swipeStamps }
        // A plain tappable surface (not a Button) so the deck's drag gesture
        // and tap-to-open don't fight — the corner buttons still take their taps.
        .contentShape(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous))
        .onTapGesture { onOpen(movie) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's pick: \(movie.title). \(reason ?? "")")
    }

    @ViewBuilder private var serviceBadge: some View {
        if let service {
            HStack(spacing: 5) {
                if let serviceLogo {
                    CachedAsyncImage(url: serviceLogo) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Color.clear
                    }
                    .frame(width: 15, height: 15)
                    .clipShape(RoundedRectangle(cornerRadius: 3.5))
                }
                Text("ON \(service.uppercased())")
                    .font(.system(size: 10, weight: .heavy)).tracking(0.5)
                    .foregroundStyle(Theme.background)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(.white.opacity(0.92)))
        }
    }

    @ViewBuilder private var swipeStamps: some View {
        // Divisor matches the 100pt action threshold so a full-opacity stamp
        // always means "release to act" (no solid stamp that snaps back).
        let save = max(0, min(dragX / 100, 1))
        let dismiss = max(0, min(-dragX / 100, 1))
        ZStack {
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .strokeBorder(Theme.scoreGreen, lineWidth: 4).opacity(save)
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .strokeBorder(Theme.scoreRed, lineWidth: 4).opacity(dismiss)
            stamp("Bookmark", "bookmark.fill", Theme.scoreGreen)
                .rotationEffect(.degrees(-10)).opacity(save)
            stamp("Pass", "xmark", Theme.scoreRed)
                .rotationEffect(.degrees(10)).opacity(dismiss)
        }
        .allowsHitTesting(false)
    }

    private func stamp(_ text: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).tracking(1)
        }
        .font(.title3.weight(.heavy))
        .foregroundStyle(.white)
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Capsule().fill(color))
        .shadow(color: .black.opacity(0.35), radius: 7, y: 2)
    }
}

/// One streamable Tonight's Pick candidate.
struct TonightCardItem: Identifiable, Equatable {
    let movie: Movie
    let reason: String
    let service: String?
    var serviceLogo: URL?
    var id: Int { movie.tmdbID }
}

/// Up to three Tonight's Picks stacked like a deck — swipe the top one away
/// (or tap ✕) to reveal the next.
struct TonightStack: View {
    let items: [TonightCardItem]
    var onOpen: (Movie) -> Void = { _ in }
    var onRank: (Movie) -> Void = { _ in }
    /// Swipe right → save to Want to Watch.
    var onSave: (TonightCardItem) -> Void = { _ in }
    /// Swipe left / ✕ → dismiss. Reported up so the feed persists it (stays gone).
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
                        movie: item.movie, reason: item.reason,
                        service: item.service, serviceLogo: item.serviceLogo,
                        dragX: idx == 0 ? drag.width : 0,
                        onOpen: onOpen, onQuickAdd: onRank,
                        onDismiss: idx == 0 ? { onDismiss(item.id) } : nil
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
            // Whenever the deck changes (a card actioned), make sure the new top
            // card isn't left carrying the previous card's drag offset.
            .onChange(of: items.count) { _, _ in drag = .zero }
        }
    }

    private func swipe(_ item: TonightCardItem) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let w = value.translation.width
                if w > 100 {            // right → save
                    fly(item, toX: 700, height: value.translation.height, save: true)
                } else if w < -100 {    // left → dismiss
                    fly(item, toX: -700, height: value.translation.height, save: false)
                } else {
                    withAnimation(.snappy) { drag = .zero }
                }
            }
    }

    /// Send the top card off-screen, then fire the action. Don't reset `drag`
    /// here — the deck shrinking triggers onChange, which resets it for the new
    /// top card (resetting now would snap the flying card back for a frame).
    private func fly(_ item: TonightCardItem, toX: CGFloat, height: CGFloat, save: Bool) {
        if save { Haptics.success() } else { Haptics.tap() }
        withAnimation(.snappy) { drag = CGSize(width: toX, height: height) }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            if save { onSave(item) } else { onDismiss(item.id) }
        }
    }
}

/// Shown in the Tonight's Pick slot once the deck is cleared (dismissed all or
/// ranked through) — a deep link to the Recs list, where there are plenty more.
struct TonightEmptyState: View {
    var onSwipe: () -> Void = {}

    var body: some View {
        HairlineCard {
            VStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Theme.marquee)
                Text("That's a wrap on tonight's picks 🎬")
                    .font(.subheadline.weight(.bold))
                Text("Fresh picks land tomorrow. Want more right now? Recs has a whole deck waiting.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                PillButton(title: "Find more in Recs", systemImage: "rectangle.stack") { onSwipe() }
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

private extension Int {
    /// Compact count for badges: 1200 -> "1.2k", 950 -> "950".
    var formattedCompact: String {
        guard self >= 1000 else { return "\(self)" }
        let k = Double(self) / 1000
        return (k >= 10 ? String(format: "%.0fk", k)
                        : String(format: "%.1fk", k).replacingOccurrences(of: ".0k", with: "k"))
    }
}
