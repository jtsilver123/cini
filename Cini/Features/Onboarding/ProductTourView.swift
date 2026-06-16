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

    private let stops: [Stop] = [
        Stop(tab: .feed, title: "Your feed",
             body: "See what friends are ranking and get recs picked for your taste."),
        Stop(tab: .feed, title: "Rank anything",
             body: "Tap the gold + in the middle to find any movie or show and rank it — that's how Cini learns your taste."),
        Stop(tab: .lists, title: "Your lists",
             body: "Everything you've ranked, each scored 1–10, plus your Want to Watch."),
        Stop(tab: .leaderboard, title: "Leaderboard",
             body: "See how your taste and activity stack up against your friends."),
        Stop(tab: .profile, title: "Your profile",
             body: "Your stats, your top films, and your settings all live here."),
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
                Text(isLast ? "Start exploring" : "Next")
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
