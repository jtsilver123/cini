import SwiftUI

// MARK: - Liquid Glass adoption (iOS 26+/27, mandatory glass era)

extension View {
    /// Capsule Liquid Glass surface where available; hairline fallback on
    /// the iOS 17 floor. Wrap sibling glass shapes in GlassEffectContainer
    /// at the call site so iOS 27 can blend and morph them.
    @ViewBuilder
    func glassCapsule(tint: Color? = nil, interactive: Bool = true) -> some View {
        if #available(iOS 26.0, *) {
            let base: Glass = tint.map { Glass.regular.tint($0) } ?? .regular
            let glass: Glass = interactive ? base.interactive() : base
            self.glassEffect(glass, in: .capsule)
        } else {
            self.background(
                Capsule().fill(tint ?? Color.white)
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: tint == nil ? 1 : 0))
            )
        }
    }
}

// MARK: - Keyboard

extension View {
    /// Swiping anywhere puts the keyboard away (complements tap-outside).
    /// Simultaneous + a real drag threshold so taps on buttons — including
    /// UIKit-backed ones like SignInWithAppleButton — are never intercepted.
    func swipeDismissesKeyboard() -> some View {
        simultaneousGesture(
            DragGesture(minimumDistance: 24).onEnded { _ in
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
            }
        )
    }
}

// MARK: - Pill buttons

/// Fully-rounded pill button. Filled velvet = primary, outlined/glass =
/// secondary. Uses the system glass button styles on iOS 26+/27 so it
/// inherits Liquid Glass refinements (and the user's transparency setting).
struct PillButton: View {
    enum Style { case filled, outlined }

    let title: String
    var systemImage: String?
    var style: Style = .filled
    var action: () -> Void = {}

    var body: some View {
        if #available(iOS 26.0, *) {
            if style == .filled {
                Button(action: action) { label(foreground: .white) }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.velvet)
            } else {
                Button(action: action) { label(foreground: Theme.marquee) }
                    .buttonStyle(.glass)
            }
        } else {
            Button(action: action) {
                label(foreground: style == .filled ? .white : Theme.marquee)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(style == .filled ? Theme.velvet : .clear))
                    .overlay(Capsule().strokeBorder(style == .filled ? .clear : Theme.marquee, lineWidth: 1.2))
            }
            .buttonStyle(.plain)
        }
    }

    private func label(foreground: Color) -> some View {
        HStack(spacing: 6) {
            if let systemImage { Image(systemName: systemImage).font(.subheadline.weight(.semibold)) }
            Text(title).font(.subheadline.weight(.semibold))
        }
        .foregroundStyle(foreground)
    }
}

/// Dropdown filter pill: "Genre ∨". Glass surface on iOS 26+/27.
struct FilterPill: View {
    let title: String
    var hasChevron = true
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.subheadline)
                if hasChevron { Image(systemName: "chevron.down").font(.caption2) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(Theme.ink)
        }
        .buttonStyle(.plain)
        .glassCapsule()
    }
}

// MARK: - Score badge

/// Circular score badge with thin ring, one-decimal score, and an optional
/// small count chip ("3k") pinned to the lower-right — exactly Beli's.
struct ScoreBadge: View {
    let score: Double
    var count: Int?
    var size: CGFloat = 52

    private var countLabel: String? {
        guard let count else { return nil }
        if count >= 1000 { return "\(count / 1000)k" }
        return "\(count)"
    }

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .strokeBorder(Theme.scoreColor(score).opacity(0.45), lineWidth: 1.8)
                .background(Circle().fill(Theme.surface))
                .frame(width: size, height: size)
                .overlay(
                    Text(score.formatted(.number.precision(.fractionLength(1))))
                        .font(.system(size: size * 0.34, weight: .bold))
                        .foregroundStyle(Theme.scoreColor(score))
                )
                .shadow(color: Theme.cardShadow, radius: 4, y: 2)
            if let countLabel {
                Text(countLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.background)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 3)
                    .background(Circle().fill(Theme.marquee))
                    .offset(x: 4, y: 4)
            }
        }
    }
}

/// Small filled rounded-rect score chip used on the detail hero ("8.4").
struct ScoreChip: View {
    let score: Double

    var body: some View {
        Text(score.formatted(.number.precision(.fractionLength(1))))
            .font(.headline.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.scoreColor(score)))
    }
}

// MARK: - Segmented pill control

/// Segmented control with active thumb (Leaderboard metrics, Search tabs).
/// The thumb is a Liquid Glass lens on iOS 26+/27.
struct SegmentedPillControl: View {
    let segments: [String]
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(segments.indices, id: \.self) { i in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = i }
                } label: {
                    Text(segments[i])
                        .font(.subheadline.weight(selection == i ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 9)
                        .background { if selection == i { thumb } }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Theme.fill))
    }

    @ViewBuilder
    private var thumb: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear).glassEffect(.regular, in: .capsule)
        } else {
            Capsule().fill(Theme.surface)
                .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        }
    }
}

// MARK: - Member row

/// The one member row: avatar, name, @username or reason line, optional
/// trailing accessory (Follow button, checkmark, …). Used by search
/// results, suggestions, and follower lists so they can't drift apart.
struct MemberRow<Accessory: View>: View {
    let avatarURL: URL?
    let title: String
    let subtitle: String
    var subtitleColor: Color = Theme.gray
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            AvatarView(url: avatarURL, size: 46)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(subtitleColor)
            }
            Spacer()
            accessory
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}

// MARK: - Cards

/// Rounded-rect card with hairline border.
struct HairlineCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline, lineWidth: 1))
            )
    }
}

// MARK: - Avatars

struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 44

    var body: some View {
        CachedAsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Circle().fill(Theme.gray.opacity(0.25))
                .overlay(Image(systemName: "person.fill").foregroundStyle(Theme.gray))
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// MARK: - Progress dots (comparison flow)

struct ProgressDots: View {
    let total: Int
    let completed: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<max(total, 1), id: \.self) { i in
                Circle()
                    .fill(i < completed ? Theme.marquee : Theme.gray.opacity(0.3))
                    .frame(width: 7, height: 7)
            }
        }
    }
}
