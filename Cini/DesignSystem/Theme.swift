import SwiftUI

/// Cini design tokens — the "movie palace" brand. Marquee gold carries
/// every interactive accent, velvet crimson fills the CTAs. Two rooms:
/// the lamp-lit charcoal screening room (dark, the default) and a warm
/// cream "matinee" light mode. Every token resolves per color scheme, so
/// the appearance setting + preferredColorScheme flips the whole app.
/// Display face: DM Serif Display.
enum Theme {

    // MARK: Adaptive color plumbing

    /// One token, two rooms: dark = the screening room (unchanged),
    /// light = the matinee.
    private static func adaptive(dark: UIColor, light: UIColor) -> Color {
        Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    private static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }

    // MARK: Colors

    /// Marquee gold — links, active states, the brand accent.
    /// (Darker in light mode so it stays readable on cream.)
    static let marquee = adaptive(dark: rgb(0xE8B64C), light: rgb(0xA9781E))
    /// Velvet crimson — filled pills, primary CTAs (cinema-curtain red).
    static let velvet = adaptive(dark: rgb(0xA8352A), light: rgb(0x9E2F25))
    /// Soft gold tint for pressed/selected states.
    static let marqueeSoft = marquee.opacity(0.16)
    /// Primary text: screen-glow cream at night, warm near-black by day.
    static let ink = adaptive(dark: rgb(0xF5EEDF), light: rgb(0x221B14))
    /// House lights down: warm charcoal · house lights up: warm cream.
    static let background = adaptive(dark: rgb(0x131011), light: rgb(0xFAF5EA))
    /// Elevated card surface.
    static let surface = adaptive(dark: rgb(0x1D1719), light: rgb(0xFFFDF6))
    /// Higher-elevation surface (badges, inputs).
    static let surface2 = adaptive(dark: rgb(0x281F20), light: rgb(0xF1EADB))
    /// Subtle fill for fields and inactive chips.
    static let fill = adaptive(dark: UIColor.white.withAlphaComponent(0.07),
                               light: UIColor.black.withAlphaComponent(0.05))
    /// Warm gray metadata text.
    static let gray = adaptive(dark: rgb(0xA69C91), light: rgb(0x84796B))
    /// Score green for high scores and match lines.
    static let scoreGreen = adaptive(dark: rgb(0x2FBF71), light: rgb(0x1D8A4F))
    /// Amber for mid scores.
    static let scoreAmber = adaptive(dark: rgb(0xE0A93E), light: rgb(0xB07F16))
    /// Muted red for low scores.
    static let scoreRed = adaptive(dark: rgb(0xD96B6B), light: rgb(0xC24444))
    /// Deep premiere gold — decorative moments: result ticket, streak flame.
    static let gold = adaptive(dark: rgb(0xD9A93C), light: rgb(0xA87B14))
    /// Hairline borders on cards and badges.
    static let hairline = adaptive(dark: UIColor.white.withAlphaComponent(0.10),
                                   light: UIColor.black.withAlphaComponent(0.12))

    /// Sentiment circles (the soft Beli trio) — same in both rooms.
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

    /// The BRAND face — Limelight, an Art Deco titling font drawn to
    /// evoke a 1920s–30s movie-theater marquee (OFL, bundled). Used for
    /// the wordmark and big section headers; all-caps by nature, so it
    /// reads like a marquee sign.
    static func display(_ size: CGFloat) -> Font {
        .custom("Limelight", size: size)
    }

    /// Editorial face for content that stays readable in mixed case
    /// (movie titles, greetings): DM Serif Display, a high-contrast
    /// poster didone (OFL). The weight parameter is kept only for
    /// call-site compatibility — the face is a single weight.
    static func serif(_ size: CGFloat, weight: Font.Weight = .bold) -> Font {
        .custom("DM Serif Display", size: size)
    }

    /// Marquee letters are wider than a didone, so the wordmark sits a
    /// touch smaller than the old serif sizes for the same footprint.
    static let wordmark = display(28)
    static let pageHeader = display(32)
    static let detailTitle = serif(36)

    // MARK: Corner radius scale
    // One consistent set instead of ad-hoc 10/14/16/18 sprinkled around.
    static let rControl: CGFloat = 12   // fields, chips, small fills
    static let rCard: CGFloat = 16      // cards, list rows, surfaces
    static let rHero: CGFloat = 22      // sheets / floating hero cards

    // MARK: Elevation

    /// Card shadow — heavy in the screening room, feather-light by day.
    static let cardShadow = adaptive(dark: UIColor.black.withAlphaComponent(0.45),
                                     light: UIColor.black.withAlphaComponent(0.12))
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
