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

/// A guided, one-time tour shown after onboarding. It steps left to right along
/// the tab bar — Feed, Swipe, Search, Your Lists, Profile — dimming the content
/// above the bar (the bar stays bright) and floating a small coachmark card over
/// the tab it's describing, with one plain line on what that tab is for.
struct ProductTourView: View {
    var onDone: () -> Void

    @State private var step = 0
    @Environment(\.horizontalSizeClass) private var hSize
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
            // The bar is the only thing left bright; everything above it dims.
            // `.ignoresSafeArea()` on the GeometryReader makes `proxy` span the
            // full screen and exposes the real insets, so we can place the dim
            // exactly above the tab bar (no magic numbers but the standard bar
            // height) on every device.
            let isPad = hSize == .regular
            let homeInset = proxy.safeAreaInsets.bottom   // home-indicator strip
            let tabBarH: CGFloat = isPad ? 65 : 49        // UITabBar height (taller on iPad)
            let barTop = max(proxy.size.height - homeInset - tabBarH, 0)
            let tabW = proxy.size.width / 5
            let cardW = min(248, proxy.size.width - 24)
            // iPad centers its tab items in a cluster (not 5 equal slots), so a
            // width/5 slot would mis-point — center the card there instead and let
            // the title + the bright bar orient the user.
            let centerX = isPad ? proxy.size.width / 2
                                : tabW * (CGFloat(tabIndex(stop.tab)) + 0.5)
            let leading = min(max(centerX - cardW / 2, 12), proxy.size.width - cardW - 12)

            ZStack(alignment: .bottomLeading) {
                // Block taps to the live app (incl. the tab bar) during the tour.
                Color.black.opacity(0.001)
                    .contentShape(Rectangle())
                    .onTapGesture { }

                // Dim ONLY the content above the tab bar — the bar stays bright,
                // so it's the one thing highlighted.
                Color.black.opacity(0.66)
                    .frame(height: barTop)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .allowsHitTesting(false)

                // The coachmark card — over the active tab, a clear gap ABOVE the
                // bar (never on top of it).
                bubble
                    .frame(width: cardW)
                    .padding(.leading, leading)
                    .padding(.bottom, homeInset + tabBarH + 12)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
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

    /// Position of each tab in the five-slot bar, so the card can sit over it.
    private func tabIndex(_ tab: RootTabView.Tab) -> Int {
        switch tab {
        case .feed: return 0
        case .swipe: return 1
        case .search: return 2
        case .lists: return 3
        case .profile: return 4
        }
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
