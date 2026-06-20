import SwiftUI

/// Lets a real on-screen control publish its frame so the product tour can aim
/// its coachmark bubble + caret right at it (e.g. the Recs view toggle). Tab-bar
/// buttons are computed geometrically instead, since the bar is UIKit.
struct TourAnchorKey: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>],
                       nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    /// Publish this view's frame under `id` so the product tour can point at it.
    func tourAnchor(_ id: String) -> some View {
        anchorPreference(key: TourAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// A little triangle that connects a coachmark bubble to the control it's about.
private struct CoachCaret: Shape {
    var pointingUp: Bool
    func path(in r: CGRect) -> Path {
        var p = Path()
        if pointingUp {
            p.move(to: CGPoint(x: r.midX, y: r.minY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        } else {
            p.move(to: CGPoint(x: r.midX, y: r.maxY))
            p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
            p.addLine(to: CGPoint(x: r.minX, y: r.minY))
        }
        p.closeSubpath()
        return p
    }
}

/// A guided, one-time tour shown after onboarding (Beli-style). It steps left
/// to right along the tab bar — Feed, Swipe, Search, Your Lists, Profile —
/// switching to each live screen and pointing a coachmark caret at that tab,
/// with one plain line on what the tab is for.
struct ProductTourView: View {
    /// Frames published by `tourAnchor` (e.g. the Recs toggle), resolved against
    /// this overlay's geometry. Tab targets are computed, so this can be empty.
    var anchors: [String: Anchor<CGRect>] = [:]
    var onDone: () -> Void

    @State private var step = 0

    private enum Target {
        case tab(Int)           // index in the 5-tab bar (feed 0 … profile 4)
        case anchor(String)     // a control that published a `tourAnchor`
    }
    private struct Stop {
        let tab: RootTabView.Tab
        let target: Target
        let title: String
        let body: String
    }

    private let stops: [Stop] = [
        Stop(tab: .feed, target: .tab(0),
             title: "Feed",
             body: "See what your friends are watching and ranking."),
        Stop(tab: .swipe, target: .tab(1),
             title: "Swipe",
             body: "Swipe through picks to find your next watch."),
        Stop(tab: .search, target: .tab(2),
             title: "Search",
             body: "Look up any movie, show, or friend — and rank what you've seen."),
        Stop(tab: .lists, target: .tab(3),
             title: "Your Lists",
             body: "Everything you rank and bookmark, all in one place."),
        Stop(tab: .profile, target: .tab(4),
             title: "Profile",
             body: "Your stats, top films, and your rank on Cini."),
    ]

    private var stop: Stop { stops[min(step, stops.count - 1)] }
    private var isLast: Bool { step >= stops.count - 1 }

    var body: some View {
        GeometryReader { proxy in
            let target = targetRect(in: proxy)
            // Target up top (e.g. the Recs toggle) → bubble sits below it with an
            // upward caret; a bottom target (a tab) → bubble above, caret down.
            let up = target.midY < proxy.size.height * 0.5
            let caretX = min(max(target.midX, 44), proxy.size.width - 44)
            let isAnchorStep: Bool = { if case .anchor = stop.target { return true } else { return false } }()

            ZStack {
                // Dim the live app and swallow taps to it.
                Color.black.opacity(0.62).ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { }

                // Gold spotlight ring — only for on-screen controls we can frame
                // precisely (the Recs toggle). Tab buttons live in the UIKit bar
                // below the bounds, so a ring there would clip; the caret + the
                // system's gold active tab mark those instead.
                if isAnchorStep {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Theme.marquee, lineWidth: 2)
                        .frame(width: target.width + 14, height: target.height + 14)
                        .position(x: target.midX, y: target.midY)
                }

                // The caret, aimed at the control.
                CoachCaret(pointingUp: up)
                    .fill(Theme.velvet)
                    .frame(width: 24, height: 12)
                    .position(x: caretX, y: up ? target.maxY + 13 : target.minY - 13)

                // The bubble, pinned just past the caret (below for top targets,
                // above for tab targets).
                bubble
                    .frame(maxWidth: 380)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: up ? .top : .bottom)
                    .padding(.top, up ? target.maxY + 20 : 0)
                    .padding(.bottom, up ? 0 : (proxy.size.height - target.minY) + 20)
            }
        }
        .onAppear { TabRouter.shared.selection = stops[0].tab }
        .animation(.snappy, value: step)
    }

    /// The frame to spotlight, in the overlay's coordinate space.
    private func targetRect(in proxy: GeometryProxy) -> CGRect {
        switch stop.target {
        case .anchor(let id):
            if let a = anchors[id] {
                let r = proxy[a]
                if r.width > 1, r.height > 1 { return r }   // ready
            }
            // Not published yet (the tab is still mounting) — approximate the
            // toggle's spot up top so the bubble starts in the right region and
            // only nudges (never flips bottom→top) once the real frame lands.
            return CGRect(x: proxy.size.width * 0.46, y: 8, width: 132, height: 36)
        case .tab(let i):
            return tabRect(i, in: proxy)
        }
    }

    /// The approximate frame of tab `i` in the bottom bar. The horizontal center
    /// is exact (the bar splits the width into five); the vertical sits in the
    /// bottom safe inset where the tab items live.
    private func tabRect(_ i: Int, in proxy: GeometryProxy) -> CGRect {
        let tabW = proxy.size.width / 5
        let cx = tabW * (CGFloat(i) + 0.5)
        let barH = min(max(proxy.safeAreaInsets.bottom, 49), 56)
        let cy = proxy.size.height + barH / 2 - 6
        return CGRect(x: cx - 27, y: cy - 20, width: 54, height: 40)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 10) {
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
        TabRouter.shared.selection = .feed       // leave them on the feed
        onDone()
        // They've arrived — rain a little welcome confetti over the feed.
        CelebrationCenter.shared.fire(.onboarding)
    }
}
