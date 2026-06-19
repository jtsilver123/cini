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

    @AppStorage("recs.demoSeen") private var demoSeen = false
    @State private var includeDemos = false
    @State private var index = 0
    @State private var drag: CGSize = .zero
    @State private var flyOff: CGFloat = 0
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
            .demo(id: 1, title: "Swipe right to save",
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
            ZStack {
                // Peek of the next card behind the top one.
                if index + 1 < items.count {
                    card(items[index + 1])
                        .scaleEffect(0.96)
                        .offset(y: 12)
                        .zIndex(0)
                }
                let top = items[index]
                card(top, dragX: drag.width + flyOff)
                    .offset(x: drag.width + flyOff, y: drag.height)
                    .rotationEffect(.degrees(Double(drag.width + flyOff) / 22))
                    .zIndex(1)
                    .gesture(
                        DragGesture()
                            .onChanged { drag = $0.translation }
                            .onEnded { value in
                                if value.translation.width > 100 { act(save: true) }
                                else if value.translation.width < -100 { act(save: false) }
                                else { withAnimation(.snappy) { drag = .zero } }
                            }
                    )
                    .animation(.snappy, value: drag)
            }
            .frame(height: 232)
        }
    }

    @ViewBuilder
    private func card(_ item: DeckItem, dragX: CGFloat = 0) -> some View {
        switch item {
        case .rec(let c):
            TonightPickCard(
                movie: c.movie, reason: c.reason,
                service: nil, showTonightBadge: false, dragX: dragX,
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
        .frame(height: 220)
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
        HStack(spacing: 28) {
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(history.isEmpty ? Theme.gray.opacity(0.4) : Theme.gold)
                    .frame(width: 46, height: 46)
                    .background(Circle().fill(Theme.fill))
            }
            .buttonStyle(.plain)
            .disabled(history.isEmpty)
            .accessibilityLabel("Undo")

            Button { act(save: false) } label: {
                Image(systemName: "xmark")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(Theme.scoreRed))
                    .shadow(color: Theme.scoreRed.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(index >= items.count)
            .accessibilityLabel("Pass")

            Button { act(save: true) } label: {
                Image(systemName: "heart.fill")
                    .font(.title.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(Theme.scoreGreen))
                    .shadow(color: Theme.scoreGreen.opacity(0.4), radius: 8, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(index >= items.count)
            .accessibilityLabel("Save to Want to Watch")
        }
    }

    private var exhausted: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle").font(.largeTitle).foregroundStyle(Theme.gray)
            Text("You're all caught up").font(.subheadline.weight(.bold))
            Text("Refresh for a fresh set, or adjust your filters.")
                .font(.caption).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
            PillButton(title: "Refresh recs", systemImage: "arrow.clockwise") {
                history.removeAll(); index = 0; onRefresh()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 232)
    }

    private func act(save: Bool) {
        guard index < items.count else { return }
        Haptics.tap()
        let item = items[index]
        if case .rec(let c) = item {
            if save {
                onSave(c.movie)
                ToastCenter.shared.show("Saved to Want to Watch ✓")
            }
            history.append((index, c.movie, save))
        } else {
            history.append((index, nil, save))
            // Past the last demo → don't show them again next time.
            if index + 1 >= demos.count { demoSeen = true }
        }
        withAnimation(.easeIn(duration: 0.28)) { flyOff = save ? 700 : -700 }
        // Advance after the card has flown off.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            index += 1
            drag = .zero
            flyOff = 0
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        // Un-save if the undone action was a save.
        if last.saved, let movie = last.movie { onUnsave(movie) }
        withAnimation(.snappy) { index = last.index; drag = .zero; flyOff = 0 }
    }
}
