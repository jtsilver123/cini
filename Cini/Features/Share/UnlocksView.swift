import SwiftUI

/// The referral-unlock catalog. Each accepted referral is one credit the user
/// spends to unlock one of these — the Beli-style "invite friends to unlock"
/// mechanic. Keys MUST match the `unlock_feature` whitelist in the DB.
struct UnlockFeature: Identifiable {
    let id: String
    let title: String
    let blurb: String
    let icon: String
    /// The fuller explanation shown when you tap the feature.
    let detail: String
}

let unlockCatalog: [UnlockFeature] = [
    UnlockFeature(id: "aggregate_scores", title: "Average Scores",
                  blurb: "See what all of Cini thinks of a movie or show — even after you rank it.",
                  icon: "chart.bar.fill",
                  detail: "Cini hides the crowd's average until you've ranked a title yourself, so it never sways your own take. Unlock this to reveal the average score from everyone on Cini on every movie and show — including after you rank. Titles with only a few ratings are pulled gently toward the middle so one stranger can't define a movie."),
    UnlockFeature(id: "social_links", title: "Social Links",
                  blurb: "Add Instagram, TikTok, X and Letterboxd links to your profile.",
                  icon: "link",
                  detail: "Add your Instagram, TikTok, X, and Letterboxd handles to your profile so friends can find you everywhere else too. They appear as tappable icons at the top of your profile — and you can edit or remove them any time."),
    UnlockFeature(id: "stealth_mode", title: "Stealth Mode",
                  blurb: "Hide specific activity from your friends' feeds.",
                  icon: "eye.slash.fill",
                  detail: "Rank or save a title without it showing up in your friends' feeds — perfect for a guilty-pleasure watch. You choose stealth per title at the moment you log it; it still counts in your own lists, scores, and stats, it's just kept off the social feed."),
]

/// Beli-style feed card: progress through the unlockable features + an invite
/// CTA. Shown near the top of the feed until everything is unlocked.
///
/// Tapping a feature circle opens its "learn more" sheet (which also unlocks it
/// if a credit is available); the button goes straight to the invite list with
/// contacts pre-loaded. There's no separate "Unlock Features" screen anymore.
struct FeedUnlockCard: View {
    @Environment(AppSession.self) private var session
    @State private var detailFeature: UnlockFeature?
    @State private var showInvite = false
    @State private var working: String?

    var body: some View {
        let unlockedCount = unlockCatalog.filter { session.isUnlocked($0.id) }.count
        let credits = session.availableUnlocks
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(credits > 0 ? "\(credits) unlock\(credits == 1 ? "" : "s") ready!" : "Unlock more of Cini")
                    .font(.headline).foregroundStyle(Theme.ink)
                Text(credits > 0
                     ? "Tap a feature below to unlock it."
                     : "Unlock features as friends join (\(unlockedCount)/\(unlockCatalog.count)) · tap one to learn more")
                    .font(.caption).foregroundStyle(Theme.gray)
            }
            HStack(spacing: 8) {
                ForEach(unlockCatalog) { feature in
                    let unlocked = session.isUnlocked(feature.id)
                    Button {
                        Haptics.tap()
                        detailFeature = feature
                    } label: {
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
                    .buttonStyle(.plain)
                }
            }
            Button {
                Haptics.tap()
                showInvite = true
            } label: {
                Text("Invite friends")
                    .font(.subheadline.weight(.bold)).foregroundStyle(.white)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.velvet))
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16).fill(Theme.surface)
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
        )
        .sheet(isPresented: $showInvite) {
            InviteSheet(autoFindContacts: true).presentationDetents([.large])
        }
        .sheet(item: $detailFeature) { feature in
            FeatureDetailSheet(
                feature: feature,
                unlocked: session.isUnlocked(feature.id),
                canUnlock: session.availableUnlocks > 0,
                onUnlock: { unlock(feature) },
                onInvite: { showInvite = true }
            )
        }
    }

    private func unlock(_ feature: UnlockFeature) {
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
    }
}

/// "Invite friends → choose what to unlock." Shows how many unlock credits the
/// user has earned and lets them spend one on any locked feature.
struct UnlocksView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var showInvite = false
    @State private var working: String?
    @State private var detailFeature: UnlockFeature?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    creditsBanner
                    Text("Tap a feature to learn more.")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
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
            .sheet(item: $detailFeature) { feature in
                FeatureDetailSheet(
                    feature: feature,
                    unlocked: session.isUnlocked(feature.id),
                    canUnlock: session.availableUnlocks > 0,
                    onUnlock: { unlock(feature) },
                    onInvite: { showInvite = true }
                )
            }
            .task { await session.loadProfile() }
        }
    }

    private func unlock(_ feature: UnlockFeature) {
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
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
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
        // Tap the row (anywhere but the Unlock button) for the full description.
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); detailFeature = feature }
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
                unlock(feature)
            } label: {
                Text("Unlock")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).frame(minHeight: 44)
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

/// The "learn more" sheet shown when a feature row is tapped.
private struct FeatureDetailSheet: View {
    let feature: UnlockFeature
    let unlocked: Bool
    let canUnlock: Bool
    var onUnlock: () -> Void
    var onInvite: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: feature.icon)
                .font(.largeTitle)
                .foregroundStyle(unlocked ? Theme.scoreGreen : Theme.marquee)
                .frame(width: 68, height: 68)
                .background(Circle().fill(unlocked ? Theme.scoreGreen.opacity(0.15) : Theme.marqueeSoft))
                .padding(.top, 12)
            Text(feature.title).font(Theme.serif(26)).foregroundStyle(Theme.ink)
            Text(feature.detail)
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            Spacer(minLength: 8)
            if unlocked {
                Label("Unlocked", systemImage: "checkmark.seal.fill")
                    .font(.headline).foregroundStyle(Theme.scoreGreen)
            } else {
                PillButton(title: canUnlock ? "Unlock now" : "Invite a friend to unlock", style: .filled) {
                    dismiss()
                    if canUnlock { onUnlock() } else { onInvite() }
                }
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
