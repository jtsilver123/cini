import SwiftUI
import Observation

// MARK: - Movie-palace atmosphere
//
// The brand is a 1920s screening room. Color + type carry most of it; these
// are the quiet finishing touches that make the room feel *lived in* — a faint
// film grain, a soft vignette, and the marquee bulbs that frame a real cinema
// sign. All are decorative, never interactive, and respect Reduce Motion /
// Reduce Transparency so they only ever add polish, never get in the way.

/// A small tile of monochrome noise, generated once and reused everywhere as
/// film grain. Rendering it as a tiled image keeps the cost to a single
/// bitmap no matter how big the surface it dresses.
enum CinemaTexture {
    static let grain: UIImage = makeGrain()

    private static func makeGrain(side: CGFloat = 130) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        return renderer.image { ctx in
            // 2pt specks read as grain at normal viewing distance without the
            // cost (or the harshness) of per-pixel noise.
            var y: CGFloat = 0
            while y < side {
                var x: CGFloat = 0
                while x < side {
                    let v = CGFloat.random(in: 0...1)
                    UIColor(white: v, alpha: 1).setFill()
                    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
                    x += 2
                }
                y += 2
            }
        }
    }
}

extension View {
    /// Faint film grain over the whole surface. Off when Reduce Transparency
    /// is on (the texture is exactly what that setting asks us to drop).
    func filmGrain(_ opacity: Double = 0.035) -> some View {
        modifier(FilmGrain(opacity: opacity))
    }

    /// A gentle darkening toward the edges — the falloff of a projector beam.
    func vignette(_ strength: Double = 0.14) -> some View {
        overlay(
            RadialGradient(colors: [.clear, .black.opacity(strength)],
                           center: .center, startRadius: 130, endRadius: 560)
                .blendMode(.multiply)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }
}

private struct FilmGrain: ViewModifier {
    let opacity: Double
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.overlay {
            if !reduceTransparency {
                Image(uiImage: CinemaTexture.grain)
                    .resizable(resizingMode: .tile)
                    .blendMode(.overlay)
                    .opacity(opacity)
                    .allowsHitTesting(false)
                    .ignoresSafeArea()
            }
        }
    }
}

/// A horizontal run of glowing marquee bulbs — the frame of a cinema sign.
/// Used to dress celebration banners so the payoff reads as a premiere.
struct MarqueeBulbStrip: View {
    var count = 9
    var bulb: CGFloat = 5
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: bulb * 1.4) {
            ForEach(0..<count, id: \.self) { i in
                Circle()
                    .fill(Theme.marquee)
                    .frame(width: bulb, height: bulb)
                    .shadow(color: Theme.marquee.opacity(0.9), radius: lit ? 4 : 1.5)
                    // Alternate bulbs chase, like a real marquee.
                    .opacity(lit ? (i.isMultiple(of: 2) ? 1 : 0.35)
                                 : (i.isMultiple(of: 2) ? 0.35 : 1))
            }
        }
        .onAppear {
            guard !reduceMotion else { return }   // hold a steady glow instead
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                lit = true
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Zoom navigation (poster flies into the detail hero, iOS 18+)
//
// A shared-element push: the tapped poster expands into the destination's hero
// instead of a hard cut. iOS 18's native API, gated cleanly to a plain push on
// the iOS 17 floor. Source and destination must share one namespace and id.

extension View {
    /// Mark this view (a poster) as the thing a zoom push grows from.
    @ViewBuilder
    func zoomSource(id: some Hashable, in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self
        }
    }

    /// Mark this destination as the target of a zoom push from `id`.
    @ViewBuilder
    func zoomDestination(id: some Hashable, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
}

/// A ring of marquee bulbs that haloes a circular element — used to crown a
/// standout score at the reveal so a 9.6 visibly outshines a 4.2.
struct MarqueeBulbRing: View {
    var diameter: CGFloat = 92
    var bulbs = 12
    var bulb: CGFloat = 5
    @State private var lit = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            ForEach(0..<bulbs, id: \.self) { i in
                Circle()
                    .fill(Theme.gold)
                    .frame(width: bulb, height: bulb)
                    .shadow(color: Theme.gold.opacity(0.9), radius: lit ? 4 : 1.5)
                    .opacity(lit ? (i.isMultiple(of: 2) ? 1 : 0.4)
                                 : (i.isMultiple(of: 2) ? 0.4 : 1))
                    .offset(y: -diameter / 2)
                    .rotationEffect(.degrees(Double(i) / Double(bulbs) * 360))
            }
        }
        .frame(width: diameter, height: diameter)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                lit = true
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Celebrations (the payoff moments)
//
// Cini used to celebrate exactly one thing — a finished rank. These are the
// *other* moments worth a flourish: milestones, streaks, finishing onboarding.
// Any screen fires one through the shared center; the overlay lives once at the
// root so confetti can fall over the whole app.

/// One celebratory beat: a short banner + a confetti burst.
struct Celebration: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var subtitle: String
    var icon: String                 // SF Symbol
    var seconds: Double = 2.6

    /// Crossing a ranked-count milestone (10th, 25th, 50th film…).
    static func rankMilestone(_ n: Int) -> Celebration {
        let subtitle: String
        switch n {
        case ..<25:   subtitle = "Your taste is taking shape."
        case ..<100:  subtitle = "You're becoming a regular."
        case ..<500:  subtitle = "A serious collection."
        default:      subtitle = "Certified cinephile."
        }
        return Celebration(title: "\(n) ranked!", subtitle: subtitle, icon: "rosette")
    }

    /// A new weekly-streak high.
    static func streak(_ weeks: Int) -> Celebration {
        Celebration(title: "\(weeks)-week streak",
                    subtitle: "Keep the marquee lit.",
                    icon: "flame.fill")
    }

    static let onboarding = Celebration(
        title: "Welcome to Cini",
        subtitle: "Your screening room is ready.",
        icon: "popcorn.fill")

    /// The very first title someone ranks — the moment the app "clicks."
    static let firstRank = Celebration(
        title: "Your first rank!",
        subtitle: "Cini's learning your taste. Keep going.",
        icon: "star.fill")
}

/// Fire-and-forget celebrations. Holds at most one at a time; firing a new one
/// replaces the last so bursts never stack.
@Observable
@MainActor
final class CelebrationCenter {
    static let shared = CelebrationCenter()

    private(set) var active: Celebration?
    private var clearTask: Task<Void, Never>?

    func fire(_ celebration: Celebration) {
        clearTask?.cancel()
        Haptics.success()
        withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) {
            active = celebration
        }
        clearTask = Task {
            try? await Task.sleep(for: .seconds(celebration.seconds))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy) { active = nil }
        }
    }

    /// The ranked-count milestones worth a flourish. Pass the count AFTER the
    /// new rank lands; fires only on the exact crossing so it can't repeat.
    static let rankMilestones: Set<Int> = [10, 25, 50, 100, 250, 500, 1000]
    func noteRankCount(_ count: Int) {
        if Self.rankMilestones.contains(count) { fire(.rankMilestone(count)) }
    }
}

/// Mounted once at the app root. Renders the active celebration's confetti +
/// banner above everything, and never eats a touch.
struct CelebrationOverlay: View {
    @State private var center = CelebrationCenter.shared

    var body: some View {
        ZStack {
            if let celebration = center.active {
                // Confetti fills the whole screen, under the status bar.
                ConfettiBurst()
                    .id(celebration.id)            // restart the burst per event
                    .ignoresSafeArea()
                    .transition(.opacity)
                // The banner stays INSIDE the safe area so it never tucks under
                // the notch / Dynamic Island.
                VStack {
                    banner(celebration)
                        .id(celebration.id)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .padding(.top, 8)
                    Spacer()
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func banner(_ c: Celebration) -> some View {
        VStack(spacing: 8) {
            MarqueeBulbStrip()
            HStack(spacing: 12) {
                Image(systemName: c.icon)
                    .font(.title2)
                    .foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                        .font(Theme.serif(22))
                        .foregroundStyle(Theme.ink)
                    Text(c.subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
            }
            MarqueeBulbStrip()
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                .fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: Theme.rHero, style: .continuous)
                    .strokeBorder(Theme.gold.opacity(0.5), lineWidth: 1))
                .shadow(color: Theme.cardShadow, radius: 18, y: 8)
        )
        .padding(.horizontal, 24)
    }
}

// MARK: - Confetti

/// A one-shot confetti fall in the brand palette. Pieces are seeded once and
/// animate from just above the screen to just below it; the overlay clears
/// itself, so there's no perpetual work. Skipped under Reduce Motion.
struct ConfettiBurst: View {
    var count = 44
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let palette: [Color] = [Theme.marquee, Theme.velvet, Theme.gold, Theme.ink]

    private let pieces: [ConfettiPiece]

    init(count: Int = 44) {
        self.count = count
        self.pieces = (0..<count).map { _ in
            ConfettiPiece(
                xFraction: .random(in: 0.02...0.98),
                hue: Self.palette.randomElement() ?? Theme.marquee,
                size: .random(in: 6...11),
                delay: .random(in: 0...0.35),
                duration: .random(in: 1.3...2.1),
                spin: .random(in: 1.5...4),
                drift: .random(in: -40...40))
        }
    }

    var body: some View {
        if reduceMotion {
            EmptyView()
        } else {
            GeometryReader { geo in
                ZStack {
                    ForEach(pieces) { piece in
                        ConfettiPieceView(piece: piece, canvas: geo.size)
                    }
                }
            }
        }
    }
}

private struct ConfettiPiece: Identifiable {
    let id = UUID()
    let xFraction: CGFloat
    let hue: Color
    let size: CGFloat
    let delay: Double
    let duration: Double
    let spin: Double
    let drift: CGFloat
}

private struct ConfettiPieceView: View {
    let piece: ConfettiPiece
    let canvas: CGSize
    @State private var fall = false

    var body: some View {
        RoundedRectangle(cornerRadius: 1.5)
            .fill(piece.hue)
            .frame(width: piece.size, height: piece.size * 0.5)
            .rotationEffect(.degrees(fall ? piece.spin * 360 : 0))
            .position(
                x: piece.xFraction * canvas.width + (fall ? piece.drift : 0),
                y: fall ? canvas.height + 24 : -24)
            .opacity(fall ? 0 : 1)
            .onAppear {
                withAnimation(.easeIn(duration: piece.duration).delay(piece.delay)) {
                    fall = true
                }
            }
    }
}
