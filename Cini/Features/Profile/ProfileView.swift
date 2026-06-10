import SwiftUI
import RankingEngine

/// One profile UI for everyone: your own tab and any member you tap into.
/// Identity → stats → (Edit/Share | Follow) → Taste Profile → Activity →
/// ranked list. Self gets the menu (import, sign out); others get Follow.
struct ProfileScreen: View {
    /// nil = the signed-in user.
    let userID: UUID?
    var username: String?

    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store

    @State private var profile: Profile?
    @State private var rankings: [RankingRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var events: [FeedEventRow] = []
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var following = false
    @State private var matchPct: Double?
    @State private var showImport = false
    @State private var detailMovie: Movie?
    @State private var loaded = false

    private var isSelf: Bool { userID == nil || userID == session.profile?.id }
    private var resolvedID: UUID? { userID ?? session.profile?.id }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                if isSelf { header }
                identity
                statRow
                buttonRow
                streakCard
                tasteSection
                activitySection
                rankedListSection
            }
            .padding(16)
        }
        .background(Theme.background)
        .sheet(isPresented: $showImport) {
            LetterboxdImportView()
        }
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .task { await load() }
    }

    // MARK: Data

    private func load() async {
        guard let id = resolvedID else { return }
        let supabase = SupabaseService.shared
        profile = try? await supabase.profile(id: id).asProfile

        if isSelf {
            rankings = (try? await supabase.rankings(userID: id)) ?? []
            movies = store.movies
        } else {
            following = await supabase.isFollowing(id)
            matchPct = await supabase.tasteMatch(with: id)
            rankings = (try? await supabase.rankings(userID: id)) ?? []
            let rows = (try? await supabase.movies(ids: rankings.map(\.movieId))) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
        }
        // Best -> worst across buckets.
        let order = ["loved": 0, "fine": 1, "disliked": 2]
        rankings.sort { (order[$0.bucket] ?? 3, $0.position) < (order[$1.bucket] ?? 3, $1.position) }

        events = (try? await supabase.events(of: id)) ?? []
        followerCount = await supabase.followCount(of: id, direction: "following_id")
        followingCount = await supabase.followCount(of: id, direction: "follower_id")
        loaded = true
    }

    // MARK: Header (self only)

    private var header: some View {
        HStack {
            Text(profile?.displayName.isEmpty == false ? profile!.displayName : "Profile")
                .font(.title2.weight(.bold))
            Spacer()
            HStack(spacing: 18) {
                ShareLink(item: URL(string: "https://cini.app/@\(profile?.username ?? "")")!) {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.ink)
                }
                Menu {
                    Button {
                        showImport = true
                    } label: {
                        Label("Import from Letterboxd or Notes", systemImage: "square.and.arrow.down")
                    }
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

    // MARK: Identity + stats

    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(url: profile?.avatarURL, size: 104)
            Text("@\(profile?.username ?? username ?? "—")").font(.headline)
            Text(profile?.memberSinceText ?? "").font(.subheadline).foregroundStyle(Theme.gray)
            if let matchPct, !isSelf {
                Text("+\(Int(matchPct))% Match")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.scoreGreen)
            }
        }
    }

    private var statRow: some View {
        HStack {
            stat("\(followerCount)", "Followers")
            stat("\(followingCount)", "Following")
            stat("\(rankings.count)", "Watched")
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold))
            Text(label).font(.subheadline).foregroundStyle(Theme.gray)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var buttonRow: some View {
        if isSelf {
            HStack(spacing: 10) {
                PillButton(title: "Edit profile", style: .outlined)
                PillButton(title: "Share profile", style: .outlined)
            }
        } else if let id = resolvedID {
            PillButton(title: following ? "Following" : "Follow",
                       style: following ? .outlined : .filled) {
                Task {
                    if following {
                        try? await SupabaseService.shared.unfollow(id)
                    } else {
                        try? await SupabaseService.shared.follow(id)
                    }
                    following.toggle()
                    await load()   // visibility may have changed
                }
            }
        }
    }

    // MARK: Streak

    @ViewBuilder
    private var streakCard: some View {
        if let p = profile, p.streakWeeks > 0 {
            HairlineCard {
                HStack(spacing: 14) {
                    Image(systemName: "flame.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.gold)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(p.streakWeeks)-week streak")
                            .font(.subheadline.weight(.bold))
                        Text(isSelf
                             ? (p.hasLoggedThisWeek ? "This week is locked in."
                                                    : "Rank one movie this week to keep it.")
                             : "Ranks at least one movie every week.")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                    if isSelf && p.hasLoggedThisWeek {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.scoreGreen)
                    }
                }
            }
        }
    }

    // MARK: Taste Profile

    private var taste: TasteSummary {
        TasteSummary(rankings: rankings, movies: movies)
    }

    @ViewBuilder
    private var tasteSection: some View {
        if !rankings.isEmpty {
            HairlineCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Taste Profile").font(.headline)

                    // Sentiment split — the brand's three circles, quantified.
                    HStack(spacing: 0) {
                        sentimentStat(taste.lovedCount, Theme.sentimentLoved, "Liked")
                        sentimentStat(taste.fineCount, Theme.sentimentFine, "Fine")
                        sentimentStat(taste.dislikedCount, Theme.sentimentDisliked, "Didn't")
                    }

                    ForEach(taste.topGenres, id: \.name) { genre in
                        HStack(spacing: 10) {
                            Text(genre.name)
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 92, alignment: .leading)
                            GeometryReader { geo in
                                Capsule().fill(Theme.fill)
                                Capsule().fill(Theme.gold)
                                    .frame(width: geo.size.width * genre.share)
                            }
                            .frame(height: 8)
                            Text("\(Int(genre.share * 100))%")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                                .frame(width: 36, alignment: .trailing)
                        }
                    }

                    if let decade = taste.favoriteDecade {
                        HStack(spacing: 6) {
                            Image(systemName: "film").font(.caption)
                            Text("Lives in the \(String(decade))s")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(Theme.teal)
                    }
                }
            }
        } else if loaded {
            HairlineCard {
                Text(isSelf ? "Rank a few movies and your taste profile appears here."
                            : "No rankings visible yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private func sentimentStat(_ count: Int, _ color: Color, _ label: String) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().fill(color.opacity(0.9)).frame(width: 44, height: 44)
                Text("\(count)").font(.subheadline.weight(.bold)).foregroundStyle(.white)
            }
            Text(label).font(.caption2).foregroundStyle(Theme.gray)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Activity

    @ViewBuilder
    private var activitySection: some View {
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Activity").font(.headline).padding(.bottom, 4)
                ForEach(events.prefix(8)) { event in
                    let movie = event.movies?.asMovie
                    HStack(spacing: 12) {
                        if let movie {
                            PosterView(url: movie.posterURL, width: 36)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(activityLine(event))
                                .font(.subheadline)
                                .lineLimit(2)
                            Text(event.createdAt.formatted(.relative(presentation: .named)))
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                    .onTapGesture { if let movie { detailMovie = movie } }
                    Divider()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityLine(_ event: FeedEventRow) -> AttributedString {
        let title = event.movies?.title ?? "a movie"
        let text: String
        switch event.eventType {
        case "ranked": text = "Ranked **\(title)**"
        case "watchlisted": text = "Added **\(title)** to watchlist"
        case "noted": text = "Wrote about **\(title)**"
        default: text = "Shared an update"
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    // MARK: Ranked list

    @ViewBuilder
    private var rankedListSection: some View {
        if !rankings.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Watched (\(rankings.count))").font(.headline).padding(.bottom, 4)
                ForEach(Array(rankings.prefix(25).enumerated()), id: \.element.id) { index, row in
                    if let movie = movies[row.movieId] {
                        HStack(spacing: 12) {
                            PosterView(url: movie.posterURL, width: 44)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(movie.title)")
                                    .font(.subheadline.weight(.semibold))
                                Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
                            }
                            Spacer()
                            ScoreBadge(score: row.score, size: 44)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                        Divider()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if loaded && !isSelf && profile?.isPrivate == true && !following {
            VStack(spacing: 6) {
                Image(systemName: "lock").font(.title2).foregroundStyle(Theme.gray)
                Text("This account is private").font(.subheadline).foregroundStyle(Theme.gray)
                Text("Follow to see their rankings.").font(.caption).foregroundStyle(Theme.gray)
            }
            .padding(.top, 12)
        }
    }
}

/// Taste profile derived from rankings + cached metadata.
struct TasteSummary {
    let lovedCount: Int
    let fineCount: Int
    let dislikedCount: Int
    let topGenres: [(name: String, share: Double)]
    let favoriteDecade: Int?

    init(rankings: [RankingRow], movies: [Int: Movie]) {
        lovedCount = rankings.filter { $0.bucket == "loved" }.count
        fineCount = rankings.filter { $0.bucket == "fine" }.count
        dislikedCount = rankings.filter { $0.bucket == "disliked" }.count

        var genreCounts: [String: Int] = [:]
        var decadeCounts: [Int: Int] = [:]
        var genreTotal = 0
        for row in rankings {
            guard let movie = movies[row.movieId] else { continue }
            for genre in movie.genres {
                genreCounts[genre, default: 0] += 1
                genreTotal += 1
            }
            if let year = movie.releaseYear {
                decadeCounts[year / 10 * 10, default: 0] += 1
            }
        }
        topGenres = genreCounts.sorted { $0.value > $1.value }.prefix(3)
            .map { ($0.key, genreTotal > 0 ? Double($0.value) / Double(genreTotal) : 0) }
        favoriteDecade = decadeCounts.max { $0.value < $1.value }?.key
    }
}

// MARK: - Entry points

/// The Profile tab — the signed-in user's own screen.
struct ProfileView: View {
    var body: some View {
        NavigationStack {
            ProfileScreen(userID: nil)
        }
    }
}
