import SwiftUI

/// Profile: avatar, @username, member-since, school, stat row, list rows,
/// rank + streak stat cards, and the annual challenge card.
struct ProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var showGoalEditor = false

    private var profile: Profile? { session.profile }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    header
                    identity
                    statRow
                    buttonRow
                    listRows
                    statCards
                    challengeCard
                }
                .padding(16)
            }
            .background(Theme.background)
            .sheet(isPresented: $showGoalEditor) {
                GoalEditorSheet()
                    .presentationDetents([.height(240)])
            }
        }
    }

    private var header: some View {
        HStack {
            Text(profile?.displayName.isEmpty == false ? profile!.displayName : "Profile")
                .font(.title2.weight(.bold))
            Spacer()
            HStack(spacing: 18) {
                Image(systemName: "square.and.arrow.up")
                Menu {
                    Button("Sign out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal").foregroundStyle(Theme.ink)
                }
            }
            .font(.title3)
        }
    }

    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(url: profile?.avatarURL, size: 110)
            Text("@\(profile?.username ?? "—")").font(.headline)
            Text(profile?.memberSinceText ?? "").font(.subheadline).foregroundStyle(Theme.gray)
            if let school = profile?.schoolLine {
                Label(school, systemImage: "graduationcap")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    private var statRow: some View {
        HStack {
            stat("\(followerCount)", "Followers")
            stat("\(followingCount)", "Following")
            stat(session.globalRank.map { "#\($0)" } ?? "—", "Rank on Cini")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold))
            Text(label).font(.subheadline).foregroundStyle(Theme.gray)
        }
        .frame(maxWidth: .infinity)
    }

    private var buttonRow: some View {
        HStack(spacing: 10) {
            PillButton(title: "Edit profile", style: .outlined)
            PillButton(title: "Share profile", style: .outlined)
            Button {} label: {
                Image(systemName: "chevron.down")
                    .padding(10)
                    .foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
            .glassCapsule()
        }
    }

    private var listRows: some View {
        VStack(spacing: 0) {
            listRow(icon: "checkmark.circle", title: "Watched", count: store.watchedCount)
            Divider()
            listRow(icon: "bookmark", title: "Watchlist", count: store.watchlistCount)
            Divider()
            listRow(icon: "heart", title: "Recs for You", count: nil)
        }
    }

    private func listRow(icon: String, title: String, count: Int?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 30)
            Text(count.map { "\(title) (\($0))" } ?? title)
                .font(.headline)
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 14)
    }

    private var statCards: some View {
        HStack(spacing: 12) {
            HairlineCard {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "trophy").font(.title3).foregroundStyle(Theme.teal)
                    Text("Rank on Cini").font(.subheadline).foregroundStyle(Theme.teal)
                    Text(session.globalRank.map { "#\($0)" } ?? "—")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.teal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HairlineCard {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "flame").font(.title3).foregroundStyle(Theme.teal)
                    Text("Current Streak").font(.subheadline).foregroundStyle(Theme.teal)
                    Text("\(profile?.streakWeeks ?? 0) weeks")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.teal)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: Annual challenge

    private var challengeCard: some View {
        let year = Calendar.current.component(.year, from: .now)
        let goal = profile?.annualGoal ?? 0
        let progress = store.challengeProgress(year: year)
        let daysLeft = daysLeftInYear()

        return HairlineCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(String(year)) Movie Challenge")
                        .font(.headline)
                        .foregroundStyle(Theme.teal)
                    Spacer()
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.ink)
                }

                if goal > 0 {
                    Text("\(progress) of \(goal) movies").font(.title3.weight(.bold))
                    ProgressView(value: min(1, Double(progress) / Double(goal)))
                        .tint(Theme.teal)
                    HStack {
                        Text("\(daysLeft) days left").font(.subheadline).foregroundStyle(Theme.gray)
                        Spacer()
                        Button {
                            showGoalEditor = true
                        } label: {
                            HStack(spacing: 2) {
                                Text("Your \(String(year)) progress")
                                Image(systemName: "chevron.right").font(.caption)
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.teal)
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Text("Set a goal for the year — one movie a week? Two hundred?")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    PillButton(title: "Set \(String(year)) goal") {
                        showGoalEditor = true
                    }
                }
            }
        }
        .task {
            await loadCounts()
        }
    }

    private func daysLeftInYear() -> Int {
        let calendar = Calendar.current
        let endOfYear = calendar.date(from: DateComponents(
            year: calendar.component(.year, from: .now) + 1, month: 1, day: 1))!
        return calendar.dateComponents([.day], from: .now, to: endOfYear).day ?? 0
    }

    private func loadCounts() async {
        guard let id = profile?.id else { return }
        let client = SupabaseService.shared.client
        if let response = try? await client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("following_id", value: id)
            .execute() {
            followerCount = response.count ?? 0
        }
        if let response = try? await client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("follower_id", value: id)
            .execute() {
            followingCount = response.count ?? 0
        }
    }
}

// MARK: - Annual goal editor

struct GoalEditorSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var goal: Double = 100

    var body: some View {
        VStack(spacing: 16) {
            Text("Annual movie goal").font(Theme.serif(24))
            Text("\(Int(goal)) movies").font(.title2.weight(.bold)).foregroundStyle(Theme.teal)
            Slider(value: $goal, in: 12...500, step: 1).tint(Theme.teal)
            PillButton(title: "Save goal") {
                Task {
                    try? await SupabaseService.shared.updateProfile(ProfileUpdate(annual_goal: Int(goal)))
                    await session.loadProfile()
                    dismiss()
                }
            }
        }
        .padding(24)
        .onAppear {
            if let existing = session.profile?.annualGoal { goal = Double(existing) }
        }
    }
}
