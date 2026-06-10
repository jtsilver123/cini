import SwiftUI

/// Cini design tokens — Beli-adjacent, adapted for film.
enum Theme {

    // MARK: Colors

    /// Primary deep teal: pills, active states, fills.
    static let teal = Color(red: 0x17 / 255, green: 0x5E / 255, blue: 0x63 / 255)
    /// Ink for primary text.
    static let ink = Color(red: 0x11 / 255, green: 0x11 / 255, blue: 0x11 / 255)
    /// Warm white app background.
    static let background = Color(red: 0xFC / 255, green: 0xFB / 255, blue: 0xF9 / 255)
    /// Gray metadata text.
    static let gray = Color(red: 0x8A / 255, green: 0x8F / 255, blue: 0x98 / 255)
    /// Score green for high scores and match lines.
    static let scoreGreen = Color(red: 0x1F / 255, green: 0x9D / 255, blue: 0x55 / 255)
    /// Amber for mid scores.
    static let scoreAmber = Color(red: 0xC9 / 255, green: 0x88 / 255, blue: 0x1A / 255)
    /// Muted red for low scores.
    static let scoreRed = Color(red: 0xB5 / 255, green: 0x4A / 255, blue: 0x4A / 255)
    /// Hairline borders on cards and badges.
    static let hairline = Color.black.opacity(0.12)

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
}
