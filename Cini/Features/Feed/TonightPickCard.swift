import SwiftUI

/// The daily hook: a "watch this tonight" pulled from your Want to Watch list,
/// pinned to the top of the feed (the `tonight_picks` RPC — highest-predicted
/// unranked saved titles). Tapping (or swiping right) opens the movie, where
/// "Where to watch" lives; the standard (+)/bookmark ride the corner.
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
    /// Swipe-stamp labels + icons. Default to Tonight's-Pick semantics; the Recs
    /// deck overrides them to "Bookmark" / "Pass" so the stamp matches its buttons.
    var rightStampText: String = "Watch tonight"
    var rightStampIcon: String = "play.fill"
    var leftStampText: String = "Not tonight"
    var leftStampIcon: String = "moon.zzz.fill"
    /// Total streaming services this is on — drives the badge's "+N".
    var providerCount: Int = 1
    /// Show the "Continue watching" badge (a show mid-binge) instead of the
    /// "Tonight's Pick" moon badge.
    var continueWatching: Bool = false
    /// Tapping the streaming badge (e.g. to see every service). When nil the
    /// badge is non-interactive (the Recs/Swipe decks don't pass it).
    var onShowProviders: (() -> Void)? = nil
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
                    Image(systemName: continueWatching ? "play.circle.fill" : "moon.stars.fill")
                    Text(continueWatching ? "CONTINUE WATCHING" : "TONIGHT'S PICK").tracking(1.5)
                }
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.onMarquee)
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
                        .frame(width: 44, height: 44)   // full 44pt tap target
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.all, 4)
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
        // Tinder-style stamps: drag right to watch tonight, left for not tonight.
        .overlay { swipeStamps }
        // A plain tappable surface (not a Button) so the deck's drag gesture
        // and tap-to-open don't fight — the corner buttons still take their taps.
        .contentShape(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous))
        .onTapGesture { onOpen(movie) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Tonight's pick: \(movie.title). \(reason ?? "")")
    }

    /// The most-popular provider's logo, plus a "+N" when it's on more — tappable
    /// to open Where-to-Watch. A dark scrim (not a white pill) so it reads on any
    /// poster in both light and dark, matching the ✕ button's scrim.
    @ViewBuilder private var serviceBadge: some View {
        if let serviceLogo {
            let chip = HStack(spacing: 5) {
                CachedAsyncImage(url: serviceLogo) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    Color.clear
                }
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                if providerCount > 1 {
                    Text("+\(providerCount - 1)")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                }
            }
            .padding(.horizontal, 6).padding(.vertical, 4)
            .background(Capsule().fill(.black.opacity(0.55)))

            if let onShowProviders {
                Button(action: onShowProviders) { chip }
                    .buttonStyle(.plain)
                    .accessibilityLabel(providerCount > 1
                        ? "On \(service ?? "a service") and \(providerCount - 1) more — see where to watch"
                        : "On \(service ?? "a service")")
            } else {
                chip
            }
        }
    }

    @ViewBuilder private var swipeStamps: some View {
        // Divisor matches the 100pt action threshold so a full-opacity stamp
        // always means "release to act" (no solid stamp that snaps back).
        let watch = max(0, min(dragX / 100, 1))
        let dismiss = max(0, min(-dragX / 100, 1))
        ZStack {
            // The swipe stamps deliberately avoid the green/amber/red score trio —
            // a swipe is a scheduling choice, not a rating. Right ("watch tonight"
            // / "bookmark") uses the gold marquee accent (the brand's primary
            // action color); left ("not tonight" / "pass") uses neutral slate so it
            // reads as "skip for now," never "I disliked this" (which red implies).
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .strokeBorder(Theme.marquee, lineWidth: 4).opacity(watch)
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .strokeBorder(Theme.slate, lineWidth: 4).opacity(dismiss)
            stamp(rightStampText, rightStampIcon, Theme.marquee, fg: Theme.background)
                .rotationEffect(.degrees(-10)).opacity(watch)
            stamp(leftStampText, leftStampIcon, Theme.slate, fg: .white)
                .rotationEffect(.degrees(10)).opacity(dismiss)
        }
        .allowsHitTesting(false)
    }

    private func stamp(_ text: String, _ icon: String, _ color: Color, fg: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text).tracking(1)
        }
        .font(.title3.weight(.heavy))
        .foregroundStyle(fg)
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
    /// The full provider data (already fetched when the card was built) so the
    /// badge can show a "+N" and tapping it can open Where-to-Watch with no
    /// extra network call.
    var providers: WatchProviders?
    /// A show the user is mid-binge on, surfaced ahead of Want to Watch — it
    /// gets the "Continue watching" badge instead of "Tonight's Pick".
    var continueWatching: Bool = false
    var id: Int { movie.tmdbID }
}

/// Up to three Tonight's Picks stacked like a deck — swipe the top one away
/// (or tap ✕) to reveal the next.
struct TonightStack: View {
    let items: [TonightCardItem]
    /// Tap → open the title's detail page. These are already on Want to Watch,
    /// so there's nothing to save — the action is "take me to it."
    var onOpen: (Movie) -> Void = { _ in }
    /// Swipe right ("watch this tonight") → open the detail page AND auto-surface
    /// Where to Watch. Distinct from a plain tap so only the deliberate swipe
    /// pulls up streaming options.
    var onWatchTonight: (Movie) -> Void = { _ in }
    var onRank: (Movie) -> Void = { _ in }
    /// Swipe left / ✕ → not tonight. Dismisses for today with NO taste signal
    /// (it's a scheduling choice, not "I don't like this"). Reported up so the
    /// feed persists it (stays gone for the day).
    var onDismiss: (Int) -> Void = { _ in }
    /// Tapped the streaming badge → open Where-to-Watch for that pick.
    var onShowProviders: (TonightCardItem) -> Void = { _ in }

    @State private var drag: CGSize = .zero
    @Environment(\.horizontalSizeClass) private var hSize
    private var isPad: Bool { hSize == .regular }
    private var cardH: CGFloat { isPad ? 420 : 220 }

    var body: some View {
        let cards = Array(items.prefix(3))
        if !cards.isEmpty {
            ZStack {
                ForEach(Array(cards.enumerated()).reversed(), id: \.element.id) { pair in
                    stackCard(pair.element, idx: pair.offset, count: cards.count)
                }
            }
            // Reserve the card height plus the stack's peek offset.
            .frame(height: cardH + 20)
            .frame(maxWidth: isPad ? 460 : .infinity)   // cap width on iPad
            .frame(maxWidth: .infinity)                 // center within the column
            // Whenever the deck changes (a card actioned), make sure the new top
            // card isn't left carrying the previous card's drag offset.
            .onChange(of: items.count) { _, _ in drag = .zero }
        }
    }

    /// One card in the stack, extracted into its own function so the big
    /// initializer + modifier chain type-checks in isolation (inline in the
    /// ForEach it tripped "unable to type-check in reasonable time"). Binding the
    /// card to a `let` separates the init's type-check from the modifier chain's.
    @ViewBuilder
    private func stackCard(_ item: TonightCardItem, idx: Int, count: Int) -> some View {
        let providerCount = item.providers?.flatrate?.count ?? 1
        let topDrag: CGFloat = idx == 0 ? drag.width : 0
        let dismiss: (() -> Void)? = idx == 0 ? { onDismiss(item.id) } : nil
        let card = TonightPickCard(
            movie: item.movie, reason: item.reason,
            service: item.service, serviceLogo: item.serviceLogo,
            height: cardH,
            dragX: topDrag,
            providerCount: providerCount,
            continueWatching: item.continueWatching,
            onShowProviders: { onShowProviders(item) },
            onOpen: onOpen, onQuickAdd: onRank,
            onDismiss: dismiss
        )
        card
            .scaleEffect(1 - CGFloat(idx) * 0.04)
            .offset(y: CGFloat(idx) * 10)
            .offset(idx == 0 ? drag : .zero)
            .rotationEffect(.degrees(idx == 0 ? Double(drag.width / 22) : 0))
            .zIndex(Double(count - idx))
            .gesture(idx == 0 ? swipe(item) : nil)
            .animation(.snappy, value: drag)
            .animation(.snappy, value: items.count)
    }

    private func swipe(_ item: TonightCardItem) -> some Gesture {
        DragGesture()
            .onChanged { drag = $0.translation }
            .onEnded { value in
                let w = value.translation.width
                if w > 100 {            // right → watch tonight: open detail + Where to Watch
                    Haptics.success()
                    onWatchTonight(item.movie)
                    // The card stays in the deck (it's still on your Want to
                    // Watch) — snap it back behind the pushed detail page.
                    withAnimation(.snappy) { drag = .zero }
                } else if w < -100 {    // left → not tonight: dismiss for today
                    fly(item, toX: -700, height: value.translation.height)
                } else {
                    withAnimation(.snappy) { drag = .zero }
                }
            }
    }

    /// Send the top card off-screen to the left, then dismiss it. Don't reset
    /// `drag` here — the deck shrinking triggers onChange, which resets it for the
    /// new top card (resetting now would snap the flying card back for a frame).
    private func fly(_ item: TonightCardItem, toX: CGFloat, height: CGFloat) {
        Haptics.tap()
        withAnimation(.snappy) { drag = CGSize(width: toX, height: height) }
        Task {
            try? await Task.sleep(for: .milliseconds(160))
            onDismiss(item.id)
        }
    }
}

/// Shown in the Tonight's Pick slot when there's no card to swipe. Three cases:
/// you have more on your Want to Watch to pull up (`showMore`), you've been
/// through everything for now (`cleared`), or there's nothing saved at all
/// (`emptyWatchlist`). The last two deep-link to Recs.
struct TonightEmptyState: View {
    enum Kind {
        /// More unshown Want-to-Watch titles exist → offer to pull up more now.
        case showMore
        /// Been through everything available for now → point to Recs.
        case cleared
        /// Nothing saved to Want to Watch yet → point to Recs to find something.
        case emptyWatchlist
        /// Saved titles exist, but none are streamable / surfaceable tonight (so
        /// no card ever showed) → an honest nudge to Recs, not a "you've been
        /// through them" message.
        case nothingTonight
    }

    var kind: Kind = .cleared
    var onSwipe: () -> Void = {}
    var onShowMore: () -> Void = {}

    init(_ kind: Kind = .cleared,
         onSwipe: @escaping () -> Void = {},
         onShowMore: @escaping () -> Void = {}) {
        self.kind = kind
        self.onSwipe = onSwipe
        self.onShowMore = onShowMore
    }

    var body: some View {
        HairlineCard {
            VStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Theme.marquee)
                Text(title)
                    .font(.subheadline.weight(.bold))
                    .multilineTextAlignment(.center)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                if kind == .showMore {
                    PillButton(title: "Show more", systemImage: "rectangle.stack.badge.plus") { onShowMore() }
                        .padding(.top, 2)
                    Button("Or browse Recs") { onSwipe() }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                } else {
                    PillButton(title: buttonTitle, systemImage: "rectangle.stack") { onSwipe() }
                        .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }

    private var icon: String {
        switch kind {
        case .showMore:       return "rectangle.stack.badge.plus"
        case .cleared:        return "sparkles"
        case .emptyWatchlist: return "popcorn.fill"
        case .nothingTonight: return "popcorn.fill"
        }
    }

    private var title: String {
        switch kind {
        case .showMore:       return "More on your list"
        case .cleared:        return "That's a wrap on tonight's picks 🎬"
        case .emptyWatchlist: return "Nothing on your Want to Watch yet 🍿"
        case .nothingTonight: return "Nothing to stream tonight 🍿"
        }
    }

    private var message: String {
        switch kind {
        case .showMore:
            return "You've been through tonight's top picks. Pull up more from your Want to Watch."
        case .cleared:
            return "Fresh picks land tomorrow. Want more right now? Recs has a whole deck waiting."
        case .emptyWatchlist:
            return "Tonight's picks come from your Want to Watch list. Find something you're excited about in Recs."
        case .nothingTonight:
            return "We couldn't find your saved titles on a streaming service right now. Browse Recs for something to watch tonight."
        }
    }

    private var buttonTitle: String {
        switch kind {
        case .showMore:       return "Show more"   // unused (showMore renders its own buttons)
        case .cleared:        return "Find more in Recs"
        case .emptyWatchlist: return "Find something in Recs"
        case .nothingTonight: return "Find something in Recs"
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
