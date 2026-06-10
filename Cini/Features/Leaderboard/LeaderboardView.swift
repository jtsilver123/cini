import SwiftUI

/// Serif "Leaderboard" header, Invite pill, Watched/Influence/Notes/Photos
/// metric control, school + genre filters, school-ranking card, ranked rows
/// with taste-match lines.
struct LeaderboardView: View {
    @Environment(AppSession.self) private var session

    @State private var metric = 0
    @State private var school: String?
    @State private var genre: String?
    @State private var rows: [LeaderboardRow] = []
    @State private var showInvite = false

    private let metrics = ["Watched", "Influence", "Notes", "Photos"]
    private let metricKeys = ["watched", "influence", "notes", "photos"]
    private let metricCopy = [
        "Number of movies on your watched list",
        "How often your rankings convert to friends' watchlist adds",
        "Number of public notes you've written",
        "Stills and tickets you've posted",
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    SegmentedPillControl(segments: metrics, selection: $metric)
                        .onChange(of: metric) { _, _ in Task { await load() } }

                    Text(metricCopy[metric])
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)

                    filters
                    schoolCard
                    rankedRows
                }
                .padding(16)
            }
            .background(Theme.background)
            .task { await load() }
            .sheet(isPresented: $showInvite) {
                InviteSheet()
                    .presentationDetents([.height(280)])
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Leaderboard").font(Theme.pageHeader)
            Spacer()
            PillButton(title: "Invite", systemImage: "person.badge.plus") {
                showInvite = true
            }
        }
    }

    private var filters: some View {
        HStack(spacing: 10) {
            Menu {
                Button("Everyone") { school = nil; Task { await load() } }
                if let mySchool = session.profile?.school {
                    Button(mySchool) { school = mySchool; Task { await load() } }
                }
            } label: {
                FilterPill(title: school ?? session.profile?.school ?? "Community")
            }
            Menu {
                Button("All Genres") { genre = nil; Task { await load() } }
                ForEach(["Drama", "Comedy", "Sci-Fi", "Horror", "Action", "Romance", "Thriller"], id: \.self) { g in
                    Button(g) { genre = g; Task { await load() } }
                }
            } label: {
                FilterPill(title: genre ?? "All Genres")
            }
        }
    }

    private var schoolCard: some View {
        HairlineCard {
            HStack(spacing: 14) {
                Image(systemName: "graduationcap")
                    .font(.title2)
                    .foregroundStyle(Theme.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your school's ranking")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(Theme.teal)
                    Text("See the overall school leaderboard")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.gray)
            }
        }
    }

    private var rankedRows: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                NavigationLink {
                    MemberProfileView(userID: row.userId, username: row.username)
                } label: {
                    HStack(spacing: 14) {
                        Text("\(index + 1)")
                            .font(.title3)
                            .foregroundStyle(Theme.gray)
                            .frame(width: 28, alignment: .leading)
                        AvatarView(url: row.avatarUrl.flatMap(URL.init), size: 48)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("@\(row.username)")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            if let pct = row.matchPct {
                                Text("+\(Int(pct))% Match")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.scoreGreen)
                            }
                        }
                        Spacer()
                        Text("\(row.value)")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
                Divider()
            }

            if rows.isEmpty {
                Text("No rankings yet — invite friends to start the race.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 24)
            }
        }
    }

    private func load() async {
        guard metric != 3 else { rows = []; return }   // photos: post-v1
        rows = (try? await SupabaseService.shared.leaderboard(
            metric: metricKeys[metric], school: school, genre: genre)) ?? []
    }
}

// MARK: - Invite sheet (growth loop)

struct InviteSheet: View {
    @Environment(AppSession.self) private var session

    private var inviteURL: URL {
        let code = session.profile?.username ?? "cini"
        return URL(string: "https://cini.app/invite/\(code)")!
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Invite friends to Cini")
                .font(Theme.serif(26))
            Text("Compare taste, race the leaderboard, and swap recs. New members auto-follow you.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            ShareLink(item: inviteURL) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share invite link").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.teal))
            }
        }
        .padding(24)
    }
}

// MARK: - Other member's profile

struct MemberProfileView: View {
    let userID: UUID
    let username: String

    @State private var profile: Profile?
    @State private var following = false

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                AvatarView(url: profile?.avatarURL, size: 96)
                Text("@\(username)").font(.headline)
                if let profile {
                    Text(profile.memberSinceText).font(.caption).foregroundStyle(Theme.gray)
                    if let school = profile.schoolLine {
                        Label(school, systemImage: "graduationcap")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                PillButton(title: following ? "Following" : "Follow",
                           style: following ? .outlined : .filled) {
                    Task {
                        if following {
                            try? await SupabaseService.shared.unfollow(userID)
                        } else {
                            try? await SupabaseService.shared.follow(userID)
                        }
                        following.toggle()
                    }
                }
            }
            .padding(24)
        }
        .background(Theme.background)
        .task {
            profile = try? await SupabaseService.shared.profile(id: userID).asProfile
        }
    }
}
