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
                  subtitle: "No one sees what you skip.", save: false),
        ] : []
    }
    private var items: [DeckItem] { demos + candidates.map(DeckItem.rec) }

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
                        .animation(.snappy, value: drag)
                }
            }
            // Hard-cap the deck to the offered width. Without this, the card's
            // full-bleed image reports its large intrinsic width up through the
            // ZStack, making the deck — and the whole Recs view — wider than the
            // screen (everything shifts off the left edge). maxWidth:.infinity
            // forces the deck to take exactly the width it's offered.
            .frame(maxWidth: .infinity)
            .frame(height: richDetail ? 300 : 220)
        }
    }

    @ViewBuilder
    private func card(_ item: DeckItem, dragX: CGFloat = 0) -> some View {
        switch item {
        case .rec(let c):
            TonightPickCard(
                movie: c.movie, reason: c.reason,
                service: richDetail ? c.movie.streamingOn.first : nil,
                showTonightBadge: false,
                height: richDetail ? 300 : 220,
                detail: richDetail ? Self.metaLine(c.movie) : nil,
                overview: richDetail ? c.movie.overview : nil,
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
                .foregroundStyle(save ? Theme.scoreGreen : Theme.scoreRed)
            Text(title).font(Theme.serif(24)).foregroundStyle(Theme.ink)
            Text(subtitle).font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            Text("Try it — practice round").font(.caption.weight(.semibold))
                .foregroundStyle(Theme.marquee)
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        // Match the rec card's height (taller in rich detail) so a real card
        // peeking behind a demo card doesn't poke out top and bottom.
        .frame(height: richDetail ? 300 : 220)
        .background(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 1))
        .overlay {
            let s = max(0, min(dragX / 100, 1))
            let d = max(0, min(-dragX / 100, 1))
            ZStack {
                RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .strokeBorder(Theme.scoreGreen, lineWidth: 4).opacity(s)
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
        HStack(alignment: .bottom, spacing: 20) {
            controlButton(action: { undo() },
                          icon: "arrow.uturn.backward", size: 46,
                          fg: history.isEmpty ? Theme.gray.opacity(0.4) : Theme.gold,
                          bg: Theme.fill, caption: "Undo")
                .disabled(history.isEmpty)
                .accessibilityLabel("Undo")

            controlButton(action: { act(save: false) },
                          icon: "xmark", size: 62, fg: .white,
                          bg: Theme.scoreRed, caption: "Pass")
                .disabled(index >= items.count)
                .accessibilityLabel("Pass")

            controlButton(action: { act(save: true) },
                          icon: "bookmark.fill", size: 62, fg: .white,
                          bg: Theme.scoreGreen, caption: "Bookmark")
                .disabled(index >= items.count)
                .accessibilityLabel("Bookmark to Want to Watch")

            // Already seen it? Rank it head-to-head. Small, balancing Undo so
            // the two big swipe buttons stay centered on the card.
            if showRank {
                controlButton(action: { rankCurrent() },
                              icon: "plus", size: 46,
                              fg: Theme.marquee, bg: Theme.fill, caption: "Rank")
                    .disabled(index >= items.count)
                    .accessibilityLabel("Rank this — you've seen it")
            }
        }
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

/// CIN-36: the same swipe deck for Friend Recs. Swipe right to save to Want to
/// Watch, left to pass — passing lets you (optionally) tell the friend why,
/// handled by the parent via `onPass`. Undo brings back the last *saved* card.
struct FriendRecDeck: View {
    let recs: [DirectRecRow]
    var onOpen: (Movie) -> Void = { _ in }
    var onLog: (Movie) -> Void = { _ in }
    var onSave: (Movie) -> Void = { _ in }
    var onUnsave: (Movie) -> Void = { _ in }
    /// Passed a card — the parent presents the "tell them why?" sheet.
    var onPass: (DirectRecRow) -> Void = { _ in }

    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var flyOff: CGFloat = 0
    @State private var lastSaved: (index: Int, movie: Movie)?

    private func reason(_ rec: DirectRecRow) -> String {
        let who = firstName(rec.profiles?.displayName, rec.profiles?.username) ?? "A friend"
        if let note = rec.note, !note.isEmpty { return "\(who): \(note)" }
        return "\(who) thinks you'll love this"
    }

    var body: some View {
        VStack(spacing: 18) {
            if index >= recs.count {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Theme.gray)
                    Text("You're all caught up").font(.subheadline.weight(.bold))
                    Text("No more friend recs to go through right now.")
                        .font(.caption).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity).frame(height: 232)
            } else {
                ZStack {
                    if index + 1 < recs.count, let next = recs[index + 1].movies?.asMovie {
                        TonightPickCard(movie: next, reason: reason(recs[index + 1]),
                                        service: nil, showTonightBadge: false)
                            .scaleEffect(0.96).offset(y: 12).zIndex(0)
                    }
                    if let movie = recs[index].movies?.asMovie {
                        TonightPickCard(movie: movie, reason: reason(recs[index]),
                                        service: nil, showTonightBadge: false,
                                        dragX: drag.width + flyOff,
                                        onOpen: onOpen, onQuickAdd: onLog, onDismiss: nil)
                            .offset(x: drag.width + flyOff, y: drag.height)
                            .rotationEffect(.degrees(Double(drag.width + flyOff) / 22))
                            .zIndex(1)
                            .gesture(
                                DragGesture()
                                    .onChanged { drag = $0.translation }
                                    .onEnded { v in
                                        if v.translation.width > 100 { act(save: true) }
                                        else if v.translation.width < -100 { act(save: false) }
                                        else { withAnimation(.snappy) { drag = .zero } }
                                    }
                            )
                            .animation(.snappy, value: drag)
                    }
                }
                .frame(height: 232)
            }
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(lastSaved == nil ? Theme.gray.opacity(0.4) : Theme.gold)
                    .frame(width: 46, height: 46).background(Circle().fill(Theme.fill))
            }
            .buttonStyle(.plain).disabled(lastSaved == nil).accessibilityLabel("Undo")

            Button { act(save: false) } label: {
                Image(systemName: "xmark").font(.title.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 62, height: 62).background(Circle().fill(Theme.scoreRed))
                    .shadow(color: Theme.scoreRed.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain).disabled(index >= recs.count).accessibilityLabel("Pass")

            Button { act(save: true) } label: {
                Image(systemName: "heart.fill").font(.title.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 62, height: 62).background(Circle().fill(Theme.scoreGreen))
                    .shadow(color: Theme.scoreGreen.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain).disabled(index >= recs.count).accessibilityLabel("Bookmark to Want to Watch")
        }
    }

    private func act(save: Bool) {
        guard index < recs.count else { return }
        Haptics.tap()
        let rec = recs[index]
        if save {
            if let movie = rec.movies?.asMovie {
                onSave(movie)
                lastSaved = (index, movie)
            }
        } else {
            lastSaved = nil
            onPass(rec)   // parent collects the optional "why" + dismisses
        }
        withAnimation(.easeIn(duration: 0.28)) { flyOff = save ? 700 : -700 }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            index += 1; drag = .zero; flyOff = 0
        }
    }

    private func undo() {
        guard let saved = lastSaved else { return }
        onUnsave(saved.movie)
        withAnimation(.snappy) { index = saved.index; drag = .zero; flyOff = 0 }
        lastSaved = nil
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
