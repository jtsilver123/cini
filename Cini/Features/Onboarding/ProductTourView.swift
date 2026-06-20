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
            let hole = tabRect(tabIndex(stop.tab), in: proxy)
            let caretX = min(max(hole.midX, 46), proxy.size.width - 46)

            ZStack {
                // Dim the whole app, but punch a rounded hole over the active
                // tab so it shows through at full brightness.
                Color.black.opacity(0.64)
                    .ignoresSafeArea()
                    .mask {
                        ZStack {
                            Rectangle().ignoresSafeArea()
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .frame(width: hole.width, height: hole.height)
                                .position(x: hole.midX, y: hole.midY)
                                .blendMode(.destinationOut)
                        }
                        .compositingGroup()
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { }   // swallow taps to the live app beneath

                // Gold ring framing the spotlighted tab.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.marquee, lineWidth: 2)
                    .frame(width: hole.width, height: hole.height)
                    .position(x: hole.midX, y: hole.midY)

                // Caret bridging the bubble down to the spotlight.
                CoachCaret()
                    .fill(Theme.velvet)
                    .frame(width: 26, height: 13)
                    .position(x: caretX, y: hole.minY - 11)

                // The coachmark bubble, sitting just above the caret.
                bubble
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, (proxy.size.height - hole.minY) + 22)
            }
        }
        .onAppear {
            TabRouter.shared.tourActive = true
            TabRouter.shared.selection = stops[0].tab
        }
        // Safety net: clear the flag if the overlay ever goes away without
        // running finish() (so Search's keyboard isn't suppressed forever).
        .onDisappear { TabRouter.shared.tourActive = false }
        .animation(.snappy, value: step)
    }

    private func tabIndex(_ tab: RootTabView.Tab) -> Int {
        switch tab {
        case .feed: return 0
        case .swipe: return 1
        case .search: return 2
        case .lists: return 3
        case .profile: return 4
        }
    }

    /// The frame of tab `i` in the bottom bar. The horizontal center is exact
    /// (the bar splits the width into five); the vertical sits in the bottom
    /// chrome where the tab items live. Sized generously so the spotlight reads
    /// as "this tab" and tolerates the bar's small per-device height variance.
    private func tabRect(_ i: Int, in proxy: GeometryProxy) -> CGRect {
        let tabW = proxy.size.width / 5
        let cx = tabW * (CGFloat(i) + 0.5)
        let barH = min(max(proxy.safeAreaInsets.bottom, 49), 60)
        // Center over the tab item (icon + label). Generous height so the
        // spotlight comfortably covers it regardless of the bar's exact height.
        let cy = proxy.size.height + barH / 2 - 14
        let w = min(tabW - 6, 82)
        let h: CGFloat = 58
        return CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("\(step + 1) of \(stops.count)")
                    .font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
                Spacer()
                Button("Skip") { finish() }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.white.opacity(0.7))
            }
            Text(stop.title)
                .font(Theme.serif(24)).foregroundStyle(.white)
            Text(stop.body)
                .font(.subheadline).foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button { isLast ? finish() : advance() } label: {
                    Text(isLast ? "Start ranking" : "Got it!")
                        .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .overlay(Capsule().strokeBorder(.white.opacity(0.9), lineWidth: 1.5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Theme.velvet)
                .shadow(color: .black.opacity(0.35), radius: 16, y: 6)
        )
        .padding(.horizontal, 18)
    }

    private func advance() {
        Haptics.tap()
        step += 1
        TabRouter.shared.selection = stop.tab   // stop reflects the new step
    }

    private func finish() {
        Haptics.tap()
        TabRouter.shared.tourActive = false
        TabRouter.shared.selection = .feed       // leave them on the feed
        onDone()
        // They've arrived — rain a little welcome confetti over the feed.
        CelebrationCenter.shared.fire(.onboarding)
    }
}
