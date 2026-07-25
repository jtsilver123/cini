import SwiftUI

/// Tactile feedback for the deck's circular controls. `.buttonStyle(.plain)`
/// gives none, and a press-only dip is invisible on a fast tap (the touch is
/// released before the spring moves). So on *release* we fire a one-shot pop
/// that plays its full duration no matter how quickly the button was tapped —
/// the button dips under the finger, then springs up past full size and settles.
private struct DeckButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DeckButtonBody(configuration: configuration)
    }

    private struct DeckButtonBody: View {
        let configuration: Configuration
        @State private var popping = false

        var body: some View {
            configuration.label
                .scaleEffect(configuration.isPressed ? 0.84 : (popping ? 1.18 : 1))
                .animation(.spring(response: 0.18, dampingFraction: 0.55),
                           value: configuration.isPressed)
                .animation(.spring(response: 0.32, dampingFraction: 0.45), value: popping)
                .onChange(of: configuration.isPressed) { _, pressed in
                    guard !pressed else { return }
                    // Released — kick the visible pop, then settle back to size.
                    popping = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(160))
                        popping = false
                    }
                }
        }
    }
}

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
    /// Passed (swiped left). The host can record it so it doesn't reappear.
    var onPass: (Movie) -> Void = { _ in }
    /// A passed/saved card was brought back via Undo — reverse any record.
    var onUndo: (Movie) -> Void = { _ in }
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
    /// One-shot reinforcement fired on the very first REAL right-swipe: the
    /// Tinder reflex reads right as "I like this / I've seen this", so the
    /// exact moment it fires is the best time to say what right actually did
    /// (saved for later) and where "I've seen it" lives (the + button).
    @AppStorage("recs.firstSaveHintShown") private var firstSaveHintShown = false
    @State private var includeDemos = false
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var flyOff: CGFloat = 0
    /// True while a card is flying off + the deck advances — blocks a second
    /// swipe from re-firing on the same card.
    @State private var advancing = false
    /// (item id, movie?, wasSave) — movie nil for demo cards. Keyed by ID,
    /// not deck index: the pool can shrink under the deck (a title ranked
    /// from another screen drops out), which would shift every raw index.
    @State private var history: [(id: String, movie: Movie?, saved: Bool)] = []
    /// The id of the card currently on top — used to re-anchor `index` when
    /// the items array mutates externally.
    @State private var topItemID: String?

    private enum DeckItem: Identifiable {
        case demo(id: Int, title: String, subtitle: String, icon: String, tint: Color)
        case rec(YourListsView.RecCandidate)
        var id: String {
            switch self {
            case .demo(let id, _, _, _, _): return "demo\(id)"
            case .rec(let c): return "rec\(c.movie.tmdbID)"
            }
        }
    }

    private var demos: [DeckItem] {
        guard includeDemos else { return [] }
        var cards: [DeckItem] = [
            // "Haven't seen it" up front — the Tinder reflex reads a right
            // swipe as "I like this / I've seen this", and that's exactly the
            // misread that files watched titles onto Want to Watch.
            .demo(id: 1, title: "Swipe right to save for later",
                  subtitle: "Haven't seen it but want to? It lands on your Want to Watch list.",
                  icon: "hand.point.right.fill", tint: Theme.marquee),
            .demo(id: 2, title: "Swipe left to pass",
                  subtitle: "Not interested — no one sees what you pass.",
                  icon: "hand.point.left.fill", tint: Theme.scoreRed),
        ]
        if showRank {
            cards.append(
                .demo(id: 3, title: "Already seen it? Tap +",
                      subtitle: "Don't swipe right on titles you've watched — the green + below ranks them head-to-head and gets you a score.",
                      icon: "plus.circle.fill", tint: Theme.scoreGreen))
        }
        return cards
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
        .onAppear {
            includeDemos = !demoSeen
            topItemID = items.indices.contains(index) ? items[index].id : nil
        }
        .onChange(of: index) { _, newIndex in
            topItemID = items.indices.contains(newIndex) ? items[newIndex].id : nil
        }
        .onChange(of: items.map(\.id)) { _, ids in
            // The pool can mutate under the deck (a title ranked from another
            // screen drops out of candidates). Re-anchor to the card the user
            // is actually looking at, not its old offset — otherwise the top
            // card is silently skipped and Undo restores the wrong card.
            if let top = topItemID, let at = ids.firstIndex(of: top) {
                if at != index {
                    var t = Transaction(); t.disablesAnimations = true
                    withTransaction(t) { index = at }
                }
            } else {
                // Top card itself left the pool — clamp and re-stamp.
                if index > ids.count { index = ids.count }
                topItemID = index < ids.count ? ids[index] : nil
            }
        }
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
                // Stamps match THIS deck's actions, not the Tonight's-Pick
                // defaults: gold "Bookmark" (the app's save color) and red "Pass"
                // (a triage rejection — distinct from Tonight's slate "not tonight,"
                // which is only a scheduling deferral).
                // The right stamp names the DESTINATION ("Want to Watch"), not
                // the verb — countering the Tinder-style misread of a right
                // swipe as "I like this / I've seen this".
                rightStampText: "Want to Watch", rightStampIcon: "bookmark.fill",
                leftStampText: "Pass", leftStampIcon: "xmark",
                rightStampColor: Theme.marquee, rightStampFg: Theme.background,
                leftStampColor: Theme.scoreRed, leftStampFg: .white,
                onOpen: onOpen, onQuickAdd: onLog, onDismiss: nil)
        case .demo(_, let title, let subtitle, let icon, let tint):
            demoCard(title: title, subtitle: subtitle, icon: icon, tint: tint, dragX: dragX)
        }
    }

    /// An instructional practice card.
    private func demoCard(title: String, subtitle: String, icon: String,
                          tint: Color, dragX: CGFloat) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(tint)
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

            controlButton(action: { tapAct(save: false) },
                          icon: "xmark", size: 62, fg: .white,
                          bg: Theme.scoreRed, caption: "Pass")
                .scaleEffect(1 + 0.12 * pass)
                .opacity(1 - 0.4 * save)
                .disabled(index >= items.count)
                .accessibilityLabel("Pass")

            controlButton(action: { tapAct(save: true) },
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
                // Captioned "Seen it" (not "Rank"): the caption's job is to
                // route the "I've watched this" case AWAY from the right swipe.
                controlButton(action: { rankCurrent() },
                              icon: "plus", size: 46,
                              fg: .white, bg: Theme.scoreGreen, caption: "Seen it")
                    .disabled(index >= items.count)
                    .accessibilityLabel("Rank this — you've seen it")
            }
        }
        // No implicit animation here: the buttons track the drag 1:1 (like the
        // card and the stamp), then ease back via the explicit withAnimation in
        // the gesture's snap-back and in act()'s fly-off.
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
            // A quick tactile press on tap (the drag-enlarge handles the gesture).
            .buttonStyle(DeckButtonStyle())
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
                history.removeAll(); index = 0; drag = .zero; flyOff = 0; onRefresh()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
    }

    /// Rank the top card (you've already seen it) — opens the head-to-head flow
    /// via the parent. The card leaves the deck once it's marked watched.
    private func rankCurrent() {
        // `!advancing` matters: during the fly-off the index still points at
        // the departing card, so a fast Rank tap would open the head-to-head
        // flow for the card that just left the deck.
        guard !advancing, index < items.count else { return }
        if case .rec(let c) = items[index] {
            Haptics.tap()
            onRank(c.movie)
        } else {
            // A practice card: tapping + IS the lesson — advance the deck.
            act(save: true, preRoll: true)
        }
    }

    /// A tapped Pass/Bookmark button — same outcome as a swipe, but a tap has no
    /// travel, so `act` pre-rolls the on-card stamp up to the threshold first.
    private func tapAct(save: Bool) { act(save: save, preRoll: true) }

    /// Commit the top card. `preRoll` rolls the stamp in first (for taps); a
    /// swipe already dragged it there. The whole sequence runs in ONE Task that
    /// releases `advancing` exactly once at the end, so a cancelled sleep can't
    /// strand the lock and freeze the deck.
    private func act(save: Bool, preRoll: Bool = false) {
        // Ignore a second action while the current card is still resolving —
        // otherwise a quick double-tap/swipe acts on the same card twice.
        guard !advancing, index < items.count else { return }
        advancing = true
        Haptics.tap()
        let item = items[index]
        if case .rec(let c) = item {
            // The card flying off is the confirmation — no toast, so a fast
            // streak isn't interrupted.
            if save { onSave(c.movie) } else { onPass(c.movie) }
            history.append((item.id, c.movie, save))
            // First-ever real save: one reinforcement at the exact moment the
            // "right = I've seen this" reflex would fire. Once, then silent.
            if save, showRank, !firstSaveHintShown {
                firstSaveHintShown = true
                ToastCenter.shared.show("Saved to Want to Watch · Seen it already? Undo, then tap +")
            }
        } else {
            history.append((item.id, nil, save))
            // Past the last demo → don't show them again next time.
            if index + 1 >= demos.count { demoSeen = true }
        }
        Task { @MainActor in
            // Fly the card off in ONE continuous motion. The card's x-offset and
            // the on-card stamp both read dragX = drag.width + flyOff, so easing
            // flyOff out to off-screen ramps the stamp in during the (slower)
            // start of the ease, then accelerates the card away — no pre-roll
            // and no dead hold, so a tap has no stop-start hitch. A tap starts
            // from drag.width = 0; a swipe continues smoothly from wherever the
            // finger let go (drag.width eases to 0 so the control buttons relax
            // in step with the departing card). Taps fly a touch slower so the
            // stamp clearly registers on the way out.
            let dir: CGFloat = save ? 1 : -1
            withAnimation(.easeIn(duration: preRoll ? 0.36 : 0.28)) {
                flyOff = drag.width + dir * 720
                drag.width = 0
            }
            try? await Task.sleep(for: .milliseconds(preRoll ? 360 : 300))
            // Advance + reset position WITHOUT animation (same transaction as the
            // index bump) so the next card appears at center, not sliding in.
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
        // Bringing a card back undoes whatever was recorded for it (pass or save).
        if let movie = last.movie {
            onUndo(movie)
            if last.saved { onUnsave(movie) }
        }
        // Resolve the card's CURRENT position — the pool may have shifted
        // since it was swiped. Gone entirely (ranked elsewhere)? The records
        // above are reversed, but there's no card to fly back in.
        guard let restored = items.firstIndex(where: { $0.id == last.id }) else { return }
        // Bring the card back: drop it in off-screen on the side it flew to
        // (no animation), then slide it home — so undo reads as "fly back in".
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            index = restored
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
