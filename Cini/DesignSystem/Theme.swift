import SwiftUI

/// Cini design tokens — Beli-adjacent, adapted for film.
/// Palette refresh: deeper teal, warm ivory ground, soft sentiment trio.
enum Theme {

    // MARK: Colors

    /// Celluloid teal — links, active states; brighter for dark surfaces.
    static let teal = Color(red: 0x3C / 255, green: 0xA0 / 255, blue: 0xA8 / 255)
    /// Deep teal for filled pills and gradients.
    static let tealDeep = Color(red: 0x14 / 255, green: 0x55 / 255, blue: 0x5A / 255)
    /// Soft teal tint for pressed/selected states.
    static let tealSoft = Color(red: 0x3C / 255, green: 0xA0 / 255, blue: 0xA8 / 255).opacity(0.16)
    /// Projector-cream primary text.
    static let ink = Color(red: 0xF2 / 255, green: 0xEF / 255, blue: 0xE9 / 255)
    /// Screening-room charcoal background.
    static let background = Color(red: 0x10 / 255, green: 0x12 / 255, blue: 0x14 / 255)
    /// Elevated card surface.
    static let surface = Color(red: 0x1A / 255, green: 0x1D / 255, blue: 0x21 / 255)
    /// Higher-elevation surface (badges, inputs).
    static let surface2 = Color(red: 0x22 / 255, green: 0x26 / 255, blue: 0x2B / 255)
    /// Subtle fill for fields and inactive chips.
    static let fill = Color.white.opacity(0.07)
    /// Gray metadata text.
    static let gray = Color(red: 0x9B / 255, green: 0xA1 / 255, blue: 0xA8 / 255)
    /// Score green for high scores and match lines.
    static let scoreGreen = Color(red: 0x2F / 255, green: 0xBF / 255, blue: 0x71 / 255)
    /// Amber for mid scores.
    static let scoreAmber = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3E / 255)
    /// Muted red for low scores.
    static let scoreRed = Color(red: 0xD9 / 255, green: 0x6B / 255, blue: 0x6B / 255)
    /// Marquee gold — premiere moments: result ticket, flash highlights.
    static let gold = Color(red: 0xD4 / 255, green: 0xAF / 255, blue: 0x37 / 255)
    /// Hairline borders on cards and badges.
    static let hairline = Color.white.opacity(0.10)

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

    /// Card shadow tuned for the dark screening room.
    static let cardShadow = Color.black.opacity(0.45)
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
