import SwiftUI

/// Cini design tokens — the "movie palace" brand. Marquee gold carries
/// every interactive accent, velvet crimson fills the CTAs, and the whole
/// room sits in a warm lamp-lit charcoal. Display face: DM Serif Display.
enum Theme {

    // MARK: Colors

    /// Marquee gold — links, active states, the brand accent.
    static let marquee = Color(red: 0xE8 / 255, green: 0xB6 / 255, blue: 0x4C / 255)
    /// Velvet crimson — filled pills, primary CTAs (cinema-curtain red).
    static let velvet = Color(red: 0xA8 / 255, green: 0x35 / 255, blue: 0x2A / 255)
    /// Soft gold tint for pressed/selected states.
    static let marqueeSoft = Color(red: 0xE8 / 255, green: 0xB6 / 255, blue: 0x4C / 255).opacity(0.16)
    /// Screen-glow cream primary text.
    static let ink = Color(red: 0xF5 / 255, green: 0xEE / 255, blue: 0xDF / 255)
    /// House-lights-down warm charcoal background.
    static let background = Color(red: 0x13 / 255, green: 0x10 / 255, blue: 0x11 / 255)
    /// Elevated card surface.
    static let surface = Color(red: 0x1D / 255, green: 0x17 / 255, blue: 0x19 / 255)
    /// Higher-elevation surface (badges, inputs).
    static let surface2 = Color(red: 0x28 / 255, green: 0x1F / 255, blue: 0x20 / 255)
    /// Subtle fill for fields and inactive chips.
    static let fill = Color.white.opacity(0.07)
    /// Warm gray metadata text.
    static let gray = Color(red: 0xA6 / 255, green: 0x9C / 255, blue: 0x91 / 255)
    /// Score green for high scores and match lines.
    static let scoreGreen = Color(red: 0x2F / 255, green: 0xBF / 255, blue: 0x71 / 255)
    /// Amber for mid scores.
    static let scoreAmber = Color(red: 0xE0 / 255, green: 0xA9 / 255, blue: 0x3E / 255)
    /// Muted red for low scores.
    static let scoreRed = Color(red: 0xD9 / 255, green: 0x6B / 255, blue: 0x6B / 255)
    /// Deep premiere gold — decorative moments: result ticket, streak flame.
    static let gold = Color(red: 0xD9 / 255, green: 0xA9 / 255, blue: 0x3C / 255)
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

    /// Display face for the wordmark and page headers ("cini",
    /// "Leaderboard", movie titles): DM Serif Display, a high-contrast
    /// poster didone bundled with the app (OFL). Single weight, so the
    /// weight parameter is kept only for call-site compatibility.
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("DM Serif Display", size: size)
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
