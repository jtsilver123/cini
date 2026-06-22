import SwiftUI

/// CIN-28: a Tinder-style swipe deck for Recs. Same card as Tonight's Pick
/// (minus the daily badge): swipe RIGHT to save to Want to Watch, LEFT to pass.
/// A couple of one-time demo cards teach the gesture; an Undo brings the last
/// card back if you swiped by accident.
struct RecCardDeck: View {
    let candidates: [YourListsView.RecCandidate]
    var onOpen: (Movie) -> Void = { _ in }
    var onLog: (Movie) -> Void = { _ in }
    /// Save / un-save (undo) to the Want to Watch list.
    var onSave: (Movie) -> Void = { _ in }
    var onUnsave: (Movie) -> Void = { _ in }
    /// Reload the deck once it's exhausted.
    var onRefresh: () -> Void = {}
    /// Show a center "+" to rank the top card (for "I've seen this"). Used by
    /// the Swipe tab; off elsewhere so the Recs decks are unchanged.
    var showRank = false
    var onRank: (Movie) -> Void = { _ in }
    /// Taller cards with a metadata line + plot summary (the Swipe tab).
    var richDetail = false
    /// Bookmark counts per tmdbID, shown as social proof on the cards.
    var bookmarkCounts: [Int: Int] = [:]

    /// "2021 · 2h 12m" — year + runtime, when known.
    static func metaLine(_ movie: Movie) -> String {
        [movie.releaseYear.map(String.init), movie.runtimeText].compactMap { $0 }.joined(separator: " · ")
    }

    @AppStorage("recs.demoSeen") private var demoSeen = false
    @State private var includeDemos = false
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var flyOff: CGFloat = 0
    /// True while a card is flying off + the deck advances — blocks a second
    /// swipe from re-firing on the same card.
    @State private var advancing = false
    /// (deckIndex, movie?, wasSave) — movie nil for demo cards.
    @State private var history: [(index: Int, movie: Movie?, saved: Bool)] = []

    private enum DeckItem: Identifiable {
        case demo(id: Int, title: String, subtitle: String, save: Bool)
        case rec(YourListsView.RecCandidate)
        var id: String {
            switch self {
            case .demo(let id, _, _, _): return "demo\(id)"
            case .rec(let c): return "rec\(c.movie.tmdbID)"
            }
        }
    }

    private var demos: [DeckItem] {
        includeDemos ? [
            .demo(id: 1, title: "Swipe right to bookmark",
                  subtitle: "It lands on your Want to Watch list.", save: true),
            .demo(id: 2, title: "Swipe left to pass",
                  subtitle: "No one sees what you pass.", save: false),
        ] : []
    }
    @Environment(\.horizontalSizeClass) private var hSize
    private var isPad: Bool { hSize == .regular }

    private var items: [DeckItem] { demos + candidates.map(DeckItem.rec) }

    /// Card height: roomy on full-size phones, trimmed on short ones (iPhone SE)
    /// so the controls below the deck never clip. On iPad the card is width-capped
    /// (below) and kept tall so it stays a portrait card, not a wide letterbox.
    private var cardHeight: CGFloat {
        guard richDetail else { return isPad ? 360 : 220 }
        return isPad ? 560 : (UIScreen.main.bounds.height > 750 ? 320 : 284)
    }
    /// Cap the deck width on iPad so the swipe card keeps phone-like proportions.
    private var deckMaxWidth: CGFloat { isPad ? 460 : .infinity }

    var body: some View {
        VStack(spacing: 18) {
            deck
            controls
        }
        .onAppear { includeDemos = !demoSeen }
    }

    @ViewBuilder
    private var deck: some View {
        if index >= items.count {
            exhausted
        } else {
            // Render the top card plus one peek behind it, KEYED BY ITEM ID.
            // The next card sits exactly behind the top (same size, no peek) so
            // nothing shows at rest. Keying by id is what stops the flicker: on
            // a quick swipe the peek becomes the new top WITHOUT being rebuilt,
            // so its artwork doesn't reload for a frame.
            let window = Array(items[index..<min(index + 2, items.count)])
            ZStack {
                ForEach(window, id: \.id) { item in
                    let isTop = item.id == items[index].id
                    card(item, dragX: isTop ? drag.width + flyOff : 0)
                        .offset(x: isTop ? drag.width + flyOff : 0,
                                y: isTop ? drag.height : 0)
                        .rotationEffect(.degrees(isTop ? Double(drag.width + flyOff) / 22 : 0))
                        .zIndex(isTop ? 1 : 0)
                        .allowsHitTesting(isTop)
                        .gesture(isTop ?
                            DragGesture()
                                .onChanged { drag = $0.translation }
                                .onEnded { value in
                                    if value.translation.width > 100 { act(save: true) }
                                    else if value.translation.width < -100 { act(save: false) }
                                    else { withAnimation(.snappy) { drag = .zero } }
                                }
                            : nil)
                        // No implicit animation on `drag`: the card must track the
                        // finger 1:1. Snap-back and fly-off use explicit
                        // withAnimation above, so removing this kills the rubber-band lag.
                }
            }
            // Hard-cap the deck to the offered width. Without this, the card's
            // full-bleed image reports its large intrinsic width up through the
            // ZStack, making the deck — and the whole Recs view — wider than the
            // screen (everything shifts off the left edge). maxWidth:.infinity
            // forces the deck to take exactly the width it's offered.
            .frame(maxWidth: deckMaxWidth)   // capped on iPad to stay portrait
            .frame(maxWidth: .infinity)      // center within the column
            .frame(height: cardHeight)
        }
    }

    @ViewBuilder
    private func card(_ item: DeckItem, dragX: CGFloat = 0) -> some View {
        switch item {
        case .rec(let c):
            TonightPickCard(
                movie: c.movie, reason: c.reason,
                // No streaming badge on the Recs cards: many movies aren't on a
                // subscription service, so it could only ever show for some — not
                // consistent. Where-to-watch lives on the detail page.
                service: nil,
                showTonightBadge: false,
                height: cardHeight,
                detail: richDetail ? Self.metaLine(c.movie) : nil,
                // Poster-forward: no overview blurb on the swipe card face — the
                // art carries it, and the full synopsis lives on the detail page.
                overview: nil,
                savedCount: bookmarkCounts[c.movie.tmdbID],
                // The deck's control bar handles save/rank now — no on-card
                // (+)/bookmark corner in the swipe deck.
                showQuickActions: false,
                dragX: dragX,
                onOpen: onOpen, onQuickAdd: onLog, onDismiss: nil)
        case .demo(_, let title, let subtitle, let save):
            demoCard(title: title, subtitle: subtitle, save: save, dragX: dragX)
        }
    }

    /// An instructional practice card.
    private func demoCard(title: String, subtitle: String, save: Bool, dragX: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: save ? "hand.point.right.fill" : "hand.point.left.fill")
                .font(.system(size: 40))
                .foregroundStyle(save ? Theme.marquee : Theme.scoreRed)
            Text(title).font(Theme.serif(24)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            Text("Try it — practice round").font(.caption.weight(.semibold))
                .foregroundStyle(Theme.marquee)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        // Match the rec card's height so a real card peeking behind a demo card
        // doesn't poke out top and bottom.
        .frame(height: cardHeight)
        .background(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay {
            let s = max(0, min(dragX / 100, 1))
            let d = max(0, min(-dragX / 100, 1))
            ZStack {
                RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .strokeBorder(Theme.marquee, lineWidth: 4).opacity(s)
                RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .strokeBorder(Theme.scoreRed, lineWidth: 4).opacity(d)
            }
            .allowsHitTesting(false)
        }
    }

    private var controls: some View {
        // Tinder-style: the two swipe actions (Pass · Bookmark) are the big
        // buttons, centered under the card; Undo and Rank are the small ones
        // flanking them, so the row stays symmetric around the card's center.
        //
        // As you drag, the matching big button swells (and the other dims) in
        // lockstep with the on-card stamp, so the gesture and the buttons read
        // as one action. A whisper, not a bounce — tied to drag progress.
        let save = max(0, min(drag.width / 100, 1))
        let pass = max(0, min(-drag.width / 100, 1))
        return HStack(alignment: .bottom, spacing: 20) {
            controlButton(action: { undo() },
                          icon: "arrow.uturn.backward", size: 46,
                          fg: history.isEmpty ? Theme.gray.opacity(0.4) : Theme.gold,
                          bg: Theme.fill, caption: "Undo")
                .disabled(history.isEmpty)
                .accessibilityLabel("Undo")

            controlButton(action: { act(save: false) },
                          icon: "xmark", size: 62, fg: .white,
                          bg: Theme.scoreRed, caption: "Pass")
                .scaleEffect(1 + 0.12 * pass)
                .opacity(1 - 0.4 * save)
                .disabled(index >= items.count)
                .accessibilityLabel("Pass")

            controlButton(action: { act(save: true) },
                          icon: "bookmark.fill", size: 62, fg: Theme.background,
                          bg: Theme.marquee, caption: "Bookmark")
                .scaleEffect(1 + 0.12 * save)
                .opacity(1 - 0.4 * pass)
                .disabled(index >= items.count)
                .accessibilityLabel("Bookmark to Want to Watch")

            // Already seen it? Rank it head-to-head. Small, balancing Undo so
            // the two big swipe buttons stay centered on the card.
            if showRank {
                // Green = rank/rate (the "loved" color), now that save is gold —
                // so the colors map cleanly: red pass · gold save · green rank.
                controlButton(action: { rankCurrent() },
                              icon: "plus", size: 46,
                              fg: .white, bg: Theme.scoreGreen, caption: "Rank")
                    .disabled(index >= items.count)
                    .accessibilityLabel("Rank this — you've seen it")
            }
        }
        .animation(.snappy, value: drag)
    }

    /// A circular action button with an optional caption beneath it, so the
    /// deck spells out what each gesture does (Pass / Seen it / Bookmark).
    private func controlButton(action: @escaping () -> Void, icon: String,
                               size: CGFloat, fg: Color, bg: Color,
                               caption: String?) -> some View {
        VStack(spacing: 5) {
            Button(action: action) {
                Image(systemName: icon)
                    .font(size >= 60 ? .title.weight(.bold) : .title2.weight(.bold))
                    .foregroundStyle(fg)
                    .frame(width: size, height: size)
                    .background(Circle().fill(bg))
                    .shadow(color: bg.opacity(bg == Theme.fill ? 0 : 0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            if let caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Theme.gray)
            }
        }
    }

    private var exhausted: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Theme.gray)
            Text("You're all caught up").font(.subheadline.weight(.bold))
            Text("Pull in new picks, or adjust your filters.")
                .font(.caption).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
            PillButton(title: "Refresh recs", systemImage: "arrow.clockwise") {
                history.removeAll(); index = 0; onRefresh()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
    }

    /// Rank the top card (you've already seen it) — opens the head-to-head flow
    /// via the parent. The card leaves the deck once it's marked watched.
    private func rankCurrent() {
        guard index < items.count, case .rec(let c) = items[index] else { return }
        Haptics.tap()
        onRank(c.movie)
    }

    private func act(save: Bool) {
        // Ignore a second swipe while the current card is still flying off —
        // otherwise a quick double-swipe acts on the same card twice and flickers.
        guard !advancing, index < items.count else { return }
        advancing = true
        Haptics.tap()
        let item = items[index]
        if case .rec(let c) = item {
            if save {
                // The card flying off to the right is the confirmation —
                // no toast, so a fast swipe streak isn't interrupted.
                onSave(c.movie)
            }
            history.append((index, c.movie, save))
        } else {
            history.append((index, nil, save))
            // Past the last demo → don't show them again next time.
            if index + 1 >= demos.count { demoSeen = true }
        }
        withAnimation(.easeIn(duration: 0.28)) { flyOff = save ? 700 : -700 }
        // Advance once the card has flown off. Reset position WITHOUT animation
        // (and in the same transaction as the index bump) so the next card just
        // appears at center instead of sliding back in from off-screen.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                index += 1
                drag = .zero
                flyOff = 0
            }
            advancing = false
        }
    }

    private func undo() {
        guard !advancing, let last = history.popLast() else { return }
        // Un-save if the undone action was a save.
        if last.saved, let movie = last.movie { onUnsave(movie) }
        // Bring the card back: drop it in off-screen on the side it flew to
        // (no animation), then slide it home — so undo reads as "fly back in".
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            index = last.index
            drag = .zero
            flyOff = last.saved ? 700 : -700
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(16))   // let the off-screen frame render
            withAnimation(.snappy) { flyOff = 0 }
        }
    }

}

/// CIN-36: after passing on a friend's rec, optionally tell them why. The
/// closure is called exactly once (Send, Skip, or swipe-to-dismiss) so the
/// pass always commits server-side.
struct PassRecMessageSheet: View {
    let rec: DirectRecRow
    var onCommit: (String?) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var committed = false

    private var who: String {
        firstName(rec.profiles?.displayName, rec.profiles?.username) ?? "your friend"
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Not your thing?").font(Theme.serif(26)).foregroundStyle(Theme.ink)
                Text("Optionally let \(who) know why you passed — they'll get a quick note.")
                    .font(.subheadline).foregroundStyle(Theme.gray)
                TextField("e.g. seen it already, not in the mood for horror…",
                          text: $message, axis: .vertical)
                    .lineLimit(2...4)
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                Spacer()
                PillButton(title: "Send to \(who)", systemImage: "paperplane") { commit(message) }
                    .frame(maxWidth: .infinity)
                    .disabled(message.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Pass without a note") { commit(nil) }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
            }
            .padding(20)
            .background(Theme.background)
            .navigationTitle("Pass on this")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium])
        // Swiped away without choosing → still commit the pass (no message).
        .onDisappear { if !committed { committed = true; Task { await onCommit(nil) } } }
    }

    private func commit(_ text: String?) {
        guard !committed else { return }
        committed = true
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await onCommit(trimmed?.isEmpty == false ? trimmed : nil) }
        if let trimmed, !trimmed.isEmpty {
            ToastCenter.shared.show("Let \(who) know — thanks for the feedback")
        }
        dismiss()
    }
}
