import SwiftUI

/// The referral-unlock catalog. Each accepted referral is one credit the user
/// spends to unlock one of these — the Beli-style "invite friends to unlock"
/// mechanic. Keys MUST match the `unlock_feature` whitelist in the DB.
struct UnlockFeature: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let icon: String
}

let unlockCatalog: [UnlockFeature] = [
    UnlockFeature(id: "aggregate_scores", title: "Average Scores",
                  blurb: "See what all of Cini thinks of a movie or show — even after you rank it.",
                  icon: "chart.bar.fill"),
    UnlockFeature(id: "social_links", title: "Social Links",
                  blurb: "Add Instagram, TikTok, X and Letterboxd links to your profile.",
                  icon: "link"),
    UnlockFeature(id: "stealth_mode", title: "Stealth Mode",
                  blurb: "Hide specific activity from your friends' feeds.",
                  icon: "eye.slash.fill"),
]

/// Beli-style feed card: progress through the unlockable features + an invite
/// CTA. Shown near the top of the feed until everything is unlocked.
struct FeedUnlockCard: View {
    @Environment(AppSession.self) private var session
    var onTap: () -> Void

    var body: some View {
        let unlockedCount = unlockCatalog.filter { session.isUnlocked($0.id) }.count
        let credits = session.availableUnlocks
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(credits > 0 ? "\(credits) unlock\(credits == 1 ? "" : "s") ready!" : "Unlock more of Cini")
                        .font(.headline).foregroundStyle(Theme.ink)
                    Text("Unlock features as friends join (\(unlockedCount)/\(unlockCatalog.count))")
                        .font(.caption).foregroundStyle(Theme.gray)
                }
                HStack(spacing: 8) {
                    ForEach(unlockCatalog) { feature in
                        let unlocked = session.isUnlocked(feature.id)
                        VStack(spacing: 6) {
                            ZStack {
                                Circle()
                                    .fill(unlocked ? Theme.scoreGreen.opacity(0.16) : Theme.surface2)
                                    .frame(width: 46, height: 46)
                                Image(systemName: unlocked ? "checkmark" : feature.icon)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(unlocked ? Theme.scoreGreen : Theme.marquee)
                            }
                            Text(feature.title)
                                .font(.caption2).foregroundStyle(Theme.gray)
                                .lineLimit(1).minimumScaleFactor(0.7)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Text(credits > 0 ? "Choose a feature to unlock" : "Invite friends")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.velvet))
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 18).fill(Theme.surface)
                    .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline, lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
    }
}

/// "Invite friends → choose what to unlock." Shows how many unlock credits the
/// user has earned and lets them spend one on any locked feature.
struct UnlocksView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var working: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    creditsBanner
                    ForEach(unlockCatalog) { feature in
                        featureCard(feature)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Unlock Features")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showInvite) {
                InviteSheet().presentationDetents([.large])
            }
            .task { await session.loadProfile() }
        }
    }

    private var creditsBanner: some View {
        let credits = session.availableUnlocks
        return VStack(spacing: 6) {
            Image(systemName: credits > 0 ? "gift.fill" : "person.2.fill")
                .font(.title)
                .foregroundStyle(Theme.marquee)
            Text(credits > 0
                 ? "\(credits) unlock\(credits == 1 ? "" : "s") to spend"
                 : "Invite a friend to earn an unlock")
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(credits > 0
                 ? "Pick a feature below to unlock it."
                 : "When a friend joins with your invite, you choose a feature to unlock.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            Button {
                Haptics.tap()
                showInvite = true
            } label: {
                Label("Invite a friend", systemImage: "person.badge.plus")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22).padding(.vertical, 11)
                    .background(Capsule().fill(Theme.velvet))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.surface))
    }

    private func featureCard(_ feature: UnlockFeature) -> some View {
        let unlocked = session.isUnlocked(feature.id)
        let canUnlock = session.availableUnlocks > 0
        return HStack(spacing: 14) {
            Image(systemName: feature.icon)
                .font(.title3)
                .foregroundStyle(unlocked ? Theme.scoreGreen : Theme.marquee)
                .frame(width: 38, height: 38)
                .background(Circle().fill(unlocked ? Theme.scoreGreen.opacity(0.15) : Theme.marqueeSoft))
            VStack(alignment: .leading, spacing: 3) {
                Text(feature.title).font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                Text(feature.blurb).font(.caption).foregroundStyle(Theme.gray)
            }
            Spacer(minLength: 8)
            trailing(feature, unlocked: unlocked, canUnlock: canUnlock)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
    }

    @ViewBuilder
    private func trailing(_ feature: UnlockFeature, unlocked: Bool, canUnlock: Bool) -> some View {
        if unlocked {
            Label("Unlocked", systemImage: "checkmark.seal.fill")
                .labelStyle(.iconOnly)
                .font(.title3)
                .foregroundStyle(Theme.scoreGreen)
        } else if working == feature.id {
            ProgressView()
        } else if canUnlock {
            Button {
                Task {
                    Haptics.tap()
                    working = feature.id
                    let ok = await SupabaseService.shared.unlockFeature(feature.id)
                    if ok {
                        await session.loadProfile()
                        ToastCenter.shared.show("\(feature.title) unlocked 🎉")
                    } else {
                        ToastCenter.shared.saveFailed()
                    }
                    working = nil
                }
            } label: {
                Text("Unlock")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Capsule().fill(Theme.velvet))
            }
            .buttonStyle(.plain)
        } else {
            Image(systemName: "lock.fill")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
        }
    }
}
