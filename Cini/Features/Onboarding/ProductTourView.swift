import SwiftUI

/// Lets a real on-screen control publish its frame (kept for any future use;
/// the tab tour below computes tab positions geometrically).
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's frame under `id` (currently unused by the tour).
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// A little triangle that connects the coachmark bubble to the tab it spotlights.
private struct CoachCaret: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.maxY))   // tip points down at the tab
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        p.closeSubpath()
        return p
    }
}

/// A guided, one-time tour shown after onboarding. It steps left to right along
/// the tab bar — Feed, Swipe, Search, Your Lists, Profile — switching to each
/// live screen and SPOTLIGHTING that tab: the rest of the screen dims, the tab
/// itself shines through a rounded cutout ringed in gold, and a coachmark bubble
/// sits just above with one plain line on what the tab is for.
struct ProductTourView: View {
    var onDone: () -> Void

    @State private var step = 0
    /// Same key SwipeView reads — the tour seeds the default card view so a new
    /// user's first look at Swipe is the deck, not the grid.
    @AppStorage("swipe.layout") private var swipeLayout = "cards"

    private struct Stop {
        let tab: RootTabView.Tab
        let title: String
        let body: String
    }

    private let stops: [Stop] = [
        Stop(tab: .feed,
             title: "Feed",
             body: "See what your friends are watching and ranking."),
        Stop(tab: .swipe,
             title: "Swipe",
             body: "Swipe through picks to find your next watch."),
        Stop(tab: .search,
             title: "Search",
             body: "Look up any movie, show, or friend — and rank what you've seen."),
        Stop(tab: .lists,
             title: "Your Lists",
             body: "Everything you rank and bookmark, all in one place."),
        Stop(tab: .profile,
             title: "Profile",
             body: "Your stats, top films, and your rank on Cini."),
    ]

    private var stop: Stop { stops[min(step, stops.count - 1)] }
    private var isLast: Bool { step >= stops.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            // Highlight the WHOLE tab bar (full width) rather than one tab — far
            // more robust than pinpointing a single UIKit tab item. The tour
            // makes the target tab the gold/active one and the bubble names it.
            let band = barBand(in: proxy)

            ZStack {
                // Dim the whole app, but cut out the tab-bar band so it shows
                // through at full brightness.
                Color.black.opacity(0.64)
                    .ignoresSafeArea()
                    .mask {
                        ZStack {
                            Rectangle().ignoresSafeArea()
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .frame(width: band.width, height: band.height)
                                .position(x: band.midX, y: band.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { }   // swallow taps to the live app beneath

                // Gold ring around the whole bar.
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Theme.marquee, lineWidth: 2)
                    .frame(width: band.width, height: band.height)
                    .position(x: band.midX, y: band.midY)

                // A single caret centered above the bar.
                CoachCaret()
                    .fill(Theme.velvet)
                    .frame(width: 22, height: 11)
                    .position(x: proxy.size.width / 2, y: band.minY - 9)

                // The coachmark bubble, sitting just above the bar.
                bubble
                    .frame(maxWidth: 360)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, (proxy.size.height - band.minY) + 18)
            }
        }
        .onAppear {
            swipeLayout = "cards"   // showcase (and seed) the default card view
            TabRouter.shared.tourActive = true
            TabRouter.shared.selection = stops[0].tab
        }
        // Safety net: clear the flag if the overlay ever goes away without
        // running finish() (so Search's keyboard isn't suppressed forever).
        .onDisappear { TabRouter.shared.tourActive = false }
        .animation(.snappy, value: step)
    }

    /// A full-width highlight band over the bottom tab bar. The bar lives in the
    /// bottom safe-area inset, so a band from just above the safe-area edge down
    /// to the screen bottom covers it on every device — no fragile per-tab math.
    private func barBand(in proxy: GeometryProxy) -> CGRect {
        let inset = max(proxy.safeAreaInsets.bottom, 49)
        let top = proxy.size.height - 6
        return CGRect(x: 8, y: top, width: proxy.size.width - 16, height: inset + 6)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("\(step + 1) of \(stops.count)")
                    .font(.caption2.weight(.semibold)).foregroundStyle(.white.opacity(0.65))
                Spacer()
                Button("Skip") { finish() }
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
            HStack(alignment: .firstTextBaseline) {
                Text(stop.title)
                    .font(Theme.serif(20)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Button { isLast ? finish() : advance() } label: {
                    Text(isLast ? "Start swiping" : "Got it!")
                        .font(.footnote.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 7)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
            Text(stop.body)
                .font(.footnote).foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.velvet)
                .shadow(color: .black.opacity(0.35), radius: 14, y: 5)
        )
        .padding(.horizontal, 20)
    }

    private func advance() {
        Haptics.tap()
        step += 1
        TabRouter.shared.selection = stop.tab   // stop reflects the new step
    }

    private func finish() {
        Haptics.tap()
        TabRouter.shared.tourActive = false
        // Land on Swipe — a new user's feed is empty, but the deck gives them
        // something to do right away (swipe to bookmark, + to rank).
        TabRouter.shared.selection = .swipe
        onDone()
        // They've arrived — rain a little welcome confetti.
        CelebrationCenter.shared.fire(.onboarding)
    }
}
