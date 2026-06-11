import SwiftUI

/// Serif "Leaderboard" header, Invite pill, Watched/Influence/Notes/Photos
/// metric control, genre filter, and ranked rows with taste-match lines.
struct LeaderboardView: View {
    @Environment(AppSession.self) private var session

    @State private var metric = 0
    @State private var genre: String?
    @State private var rows: [LeaderboardRow] = []
    @State private var showInvite = false

    private let metrics = ["Watched", "Influence", "Notes"]
    private let metricKeys = ["watched", "influence", "notes"]
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
                Button("All Genres") { genre = nil; Task { await load() } }
                ForEach(["Drama", "Comedy", "Sci-Fi", "Horror", "Action", "Romance", "Thriller"], id: \.self) { g in
                    Button(g) { genre = g; Task { await load() } }
                }
            } label: {
                FilterPill(title: genre ?? "All Genres")
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
                VStack(spacing: 6) {
                    Image(systemName: "trophy")
                        .font(.title2)
                        .foregroundStyle(Theme.gray)
                    Text("No rankings yet — invite friends to start the race.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
        }
    }

    private func load() async {
        rows = (try? await SupabaseService.shared.leaderboard(
            metric: metricKeys[metric], genre: genre)) ?? []
    }
}

// MARK: - Invite sheet (growth loop)

struct InviteSheet: View {
    @Environment(AppSession.self) private var session

    private var inviteText: String {
        "Join me on Cini — we rank every movie head-to-head 🎬 Enter my username (\(session.profile?.username ?? "me")) when you sign up and we'll follow each other automatically."
    }

    var body: some View {
        VStack(spacing: 18) {
            Text("Invite friends to Cini")
                .font(Theme.serif(26))
            Text("Compare taste, race the leaderboard, and swap recs. Friends who enter your @username at signup follow you automatically.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            ShareLink(item: inviteText) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Share invite link").font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Capsule().fill(Theme.velvet))
            }
        }
        .padding(24)
    }
}

// MARK: - Other member's profile — same UI as your own.

struct MemberProfileView: View {
    let userID: UUID
    let username: String

    var body: some View {
        ProfileScreen(userID: userID, username: username)
    }
}
