import SwiftUI

/// A short guided tour shown once after onboarding (Beli-style). Instead of a
/// static carousel, it actually walks people around the app: each step switches
/// the live tab so they see the real screen, with the content dimmed but the tab
/// bar kept bright (the system already highlights the active tab in gold). The
/// Search "+" step is described in place — switching to Search would raise the
/// keyboard and cover the card.
struct ProductTourView: View {
    var onDone: () -> Void

    @State private var step = 0

    private struct Stop {
        let tab: RootTabView.Tab
        let title: String
        let body: String
    }

    // A walkthrough of the actual loop — what to tap and why — not a tour of
    // tab names. Each stop switches to the live screen so the real thing is
    // behind the card, and the gold active tab anchors where to look.
    private let stops: [Stop] = [
        Stop(tab: .feed, title: "Rank what you've watched",
             body: "Tap the gold + and search any movie or show. Cini asks which of two you liked more — a few quick picks and it scores everything 1–10, your taste, not strangers'."),
        Stop(tab: .swipe, title: "Find what to watch next",
             body: "Recs are tuned to your taste. Swipe right to save to Want to Watch, left to pass, or tap + to rank one you've already seen."),
        Stop(tab: .feed, title: "See friends & compare taste",
             body: "Your feed is what friends are ranking. Like it, comment, or tap “Compare taste” on anyone to see how aligned you two are."),
        Stop(tab: .lists, title: "Find it all later",
             body: "Everything you rank (each scored 1–10) and every title you bookmark lives in Your Lists — plus any lists you make."),
        Stop(tab: .profile, title: "You're all set 🎬",
             body: "Your stats, top films, and the leaderboard live here. Best first move: rank a handful of titles you love."),
    ]

    private var stop: Stop { stops[min(step, stops.count - 1)] }
    private var isLast: Bool { step >= stops.count - 1 }

    var body: some View {
        GeometryReader { geo in
            let tabBarH = geo.safeAreaInsets.bottom + 52
            ZStack(alignment: .bottom) {
                // Dim the content, but keep the tab bar bright so the gold
                // active tab the tour is describing stands out.
                VStack(spacing: 0) {
                    Rectangle().fill(.black.opacity(0.6))
                    Rectangle().fill(.black.opacity(0.05)).frame(height: tabBarH)
                }
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }   // block taps to the dimmed app

                card
                    .frame(maxWidth: 520)
                    .padding(.horizontal, 18)
                    .padding(.bottom, tabBarH + 10)
                    .transition(.opacity)
            }
        }
        .onAppear { TabRouter.shared.selection = stops[0].tab }
        .animation(.snappy, value: step)
    }

    private var card: some View {
        VStack(spacing: 14) {
            HStack {
                Text("\(step + 1) of \(stops.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(Theme.gray)
                Spacer()
                Button("Skip") { finish() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.gray)
            }
            VStack(spacing: 6) {
                Text(stop.title)
                    .font(Theme.serif(26)).foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.center)
                Text(stop.body)
                    .font(.subheadline).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
            }
            // Points at the tab bar below — the screen they're being shown.
            Image(systemName: "arrow.down")
                .font(.headline.weight(.bold)).foregroundStyle(Theme.marquee)

            Button {
                if isLast { finish() } else { advance() }
            } label: {
                Text(isLast ? "Start ranking" : "Got it!")
                    .font(.headline).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Capsule().fill(Theme.velvet))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .fill(Theme.surface)
                .shadow(color: Theme.cardShadow, radius: 22, y: 8)
        )
    }

    private func advance() {
        Haptics.tap()
        step += 1
        TabRouter.shared.selection = stop.tab   // stop reflects the new step
    }

    private func finish() {
        Haptics.tap()
        TabRouter.shared.selection = .feed       // leave them on the feed
        onDone()
        // They've arrived — rain a little welcome confetti over the feed.
        CelebrationCenter.shared.fire(.onboarding)
    }
}
