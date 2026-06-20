import SwiftUI

/// Explains the ranking streak when the flame chip in the feed header is tapped.
/// Plain language: what a streak is, how to keep it, what breaks it — plus a
/// one-tap path to go rank something.
struct StreakInfoSheet: View {
    let weeks: Int
    let atRisk: Bool
    /// Called when they tap the CTA — dismisses and routes to ranking.
    var onRank: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 18) {
            // Flame + current count.
            ZStack {
                Circle()
                    .fill(Theme.gold.opacity(0.14))
                    .frame(width: 84, height: 84)
                Image(systemName: "flame.fill")
                    .font(.system(size: 38))
                    .foregroundStyle(Theme.gold)
            }
            .padding(.top, 28)

            Text(weeks > 0
                 ? "\(weeks)-week streak"
                 : "Start a streak")
                .font(Theme.serif(26))
                .foregroundStyle(Theme.ink)

            Text(streakLine)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 28)

            // The two rules, stated simply.
            VStack(alignment: .leading, spacing: 12) {
                ruleRow("calendar", "Rank at least one movie or show each week to keep your streak going.")
                ruleRow("arrow.counterclockwise", "Miss a week and it resets to zero — so keep it alive.")
            }
            .padding(.horizontal, 24)
            .padding(.top, 4)

            Spacer(minLength: 0)

            PillButton(title: "Rank something", style: .filled) { onRank() }
                .padding(.horizontal, 24)
            Button("Got it") { dismiss() }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }

    private var streakLine: String {
        if atRisk {
            return "Your streak ends Sunday — rank one title this week to keep it alive."
        }
        if weeks > 0 {
            return "You've ranked something every week for \(weeks) week\(weeks == 1 ? "" : "s") running. Nice."
        }
        return "Rank a title this week to begin your streak — then keep it going week after week."
    }

    private func ruleRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gold)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
