import SwiftUI

/// Cini design tokens — Beli-adjacent, adapted for film.
/// Palette refresh: deeper teal, warm ivory ground, soft sentiment trio.
enum Theme {

    // MARK: Colors

    /// Primary deep teal: pills, active states, fills.
    static let teal = Color(red: 0x14 / 255, green: 0x55 / 255, blue: 0x5A / 255)
    /// Lighter teal for tints and pressed states.
    static let tealSoft = Color(red: 0x14 / 255, green: 0x55 / 255, blue: 0x5A / 255).opacity(0.10)
    /// Ink for primary text.
    static let ink = Color(red: 0x12 / 255, green: 0x14 / 255, blue: 0x16 / 255)
    /// Warm ivory app background.
    static let background = Color(red: 0xFA / 255, green: 0xF7 / 255, blue: 0xF2 / 255)
    /// Card surface.
    static let surface = Color.white
    /// Gray metadata text.
    static let gray = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x98 / 255)
    /// Score green for high scores and match lines.
    static let scoreGreen = Color(red: 0x1F / 255, green: 0x9D / 255, blue: 0x55 / 255)
    /// Amber for mid scores.
    static let scoreAmber = Color(red: 0xC9 / 255, green: 0x88 / 255, blue: 0x1A / 255)
    /// Muted red for low scores.
    static let scoreRed = Color(red: 0xB5 / 255, green: 0x4A / 255, blue: 0x4A / 255)
    /// Hairline borders on cards and badges.
    static let hairline = Color.black.opacity(0.10)

    /// Sentiment circles (the soft Beli trio).
    static let sentimentLoved = Color(red: 0x53 / 255, green: 0xB1 / 255, blue: 0x7C / 255)
    static let sentimentFine = Color(red: 0xF4 / 255, green: 0xC9 / 255, blue: 0x5C / 255)
    static let sentimentDisliked = Color(red: 0xEE / 255, green: 0x9E / 255, blue: 0x9E / 255)

    static func scoreColor(_ score: Double) -> Color {
        switch score {
        case 6.7...: return scoreGreen
        case 3.4..<6.7: return scoreAmber
        default: return scoreRed
        }
    }

    // MARK: Type

    /// Serif display face for the wordmark and page headers
    /// ("cini", "Leaderboard", movie titles). New York via system serif.
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    static let wordmark = serif(34)
    static let pageHeader = serif(40)
    static let detailTitle = serif(36)

    // MARK: Elevation

    /// Soft card shadow used across stacked cards and posters.
    static let cardShadow = Color.black.opacity(0.07)
}

/// Floating card used by the log-flow stack and elsewhere.
struct FloatingCard: ViewModifier {
    var cornerRadius: CGFloat = 22

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Theme.cardShadow, radius: 16, y: 6)
            )
    }
}

extension View {
    func floatingCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(FloatingCard(cornerRadius: cornerRadius))
    }
}
