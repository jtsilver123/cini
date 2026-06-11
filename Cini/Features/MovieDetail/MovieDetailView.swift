import SwiftUI
import RankingEngine

/// Movie detail — mirrors Beli's restaurant page: backdrop hero, serif title,
/// community score, "Rank again", tags, metadata, social proof, action pills,
/// the three-circle Scores section, Top Performances, ratings histogram, and
/// "What your friends think".
struct MovieDetailView: View {
    @State var movie: Movie

    @Environment(RankingStore.self) private var store

    @State private var community: CommunityScore?
    @State private var friends: [FriendScoreRow] = []
    @State private var histogram: [HistogramBin] = []
    @State private var performances: [PerformanceCount] = []
    @State private var providers: WatchProviders?
    @State private var trailerURL: URL?
    @State private var tags: [String] = []
    @State private var myDetails: SupabaseService.MyMovieDetails?
    @State private var cast: [CastMember] = []
    @State private var extended: TMDBService.ExtendedDetails?
    @State private var summaryExpanded = false
    @State private var showAllCast = false
    @State private var showLogFlow = false
    @State private var showWhereToWatch = false
    @State private var showShowtimes = false
    @State private var showSendRec = false
    @State private var memberTarget: MemberRef?
    @State private var peopleTab: PeopleTab = .friends
    @State private var publicNotes: [PublicNoteRow] = []
    @State private var publicNotesLoaded = false
    @State private var commentsTarget: CommentsTarget?

    enum PeopleTab: String, CaseIterable {
        case friends = "Friends"
        case everyone = "Everyone"
    }

    struct CommentsTarget: Identifiable {
        let id: UUID
    }

    private var myItem: ScoredItem<Int>? { store.scoredItem(for: movie.tmdbID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                tagRow
                metadataBlock
                summarySection
                actionPills
                scoresSection
                histogramSection
                yourDetailsSection
                castSection
                detailsSection
                performancesSection
                peopleSection
            }
            .padding(.bottom, 32)
        }
        .background(Theme.background)
        .ignoresSafeArea(edges: .top)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: "\(movie.title) — on my Cini list 🎬") {
                    Image(systemName: "square.and.arrow.up")
                }
            }
        }
        .fullScreenCover(isPresented: $showLogFlow) {
            LogFlowView(movie: movie)
        }
        .sheet(isPresented: $showWhereToWatch) {
            WhereToWatchSheet(movie: movie, providers: providers)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showShowtimes) {
            ShowtimesSheet(movie: movie)
        }
        .sheet(isPresented: $showSendRec) {
            SendRecSheet(movie: movie)
        }
        // Presented from the screen root — sheets attached deep inside the
        // scrolling stack can silently fail to appear on device.
        .sheet(item: $commentsTarget) { target in
            CommentsSheet(eventID: target.id)
                .presentationDetents([.medium, .large])
        }
        .task { await loadEverything() }
    }

    // MARK: Sections

    @State private var heroAppeared = false

    /// Beli-style hero: the artwork fades into the page so the title,
    /// score, and CTAs sit ON it and stay perfectly readable.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            CachedAsyncImage(url: movie.backdropURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(Theme.gray.opacity(0.2))
            }
            .scaleEffect(heroAppeared ? 1 : 1.06)
            .opacity(heroAppeared ? 1 : 0.6)

            // Artwork dissolves into the background under the info block —
            // an eased curve so there's no visible band, just a melt.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: Theme.background.opacity(0.10), location: 0.38),
                    .init(color: Theme.background.opacity(0.34), location: 0.56),
                    .init(color: Theme.background.opacity(0.62), location: 0.70),
                    .init(color: Theme.background.opacity(0.85), location: 0.82),
                    .init(color: Theme.background.opacity(0.96), location: 0.92),
                    .init(color: Theme.background, location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(movie.title)
                    .font(Theme.detailTitle)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)

                HStack(spacing: 10) {
                    if let community {
                        ScoreChip(score: community.avgScore)
                        Text("(\(community.ratingCount.formatted()) ratings)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                    }
                    Spacer()
                    if myItem != nil {
                        // Already ranked: Beli's "Rank again" pill + check.
                        Button {
                            showLogFlow = true
                        } label: {
                            Text("Rank again")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Theme.fill))
                                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        Image(systemName: "checkmark.circle")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(Theme.scoreGreen)
                    } else {
                        ArtworkQuickActions(movie: movie) { _ in
                            showLogFlow = true
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
        .frame(height: 300)
        .clipped()
        .onAppear {
            withAnimation(.snappy(duration: 0.5)) { heroAppeared = true }
        }
    }

    /// Community labels for THIS movie (what members tagged it while
    /// ranking); TMDB theme keywords until anyone has. Hidden when neither
    /// exists yet.
    @ViewBuilder
    private var tagRow: some View {
        if !tags.isEmpty {
            Text(tags.prefix(4).joined(separator: " · "))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .padding(.horizontal, 16)
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(movie.metadataLine).font(.subheadline)
            Text([movie.releaseYear.map(String.init), movie.runtimeText,
                  movie.director.map { "Dir. \($0)" }]
                .compactMap(\.self).joined(separator: " · "))
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
        }
        .padding(.horizontal, 16)
    }

    /// Three actions, always visible — no horizontal scrolling needed.
    /// (The trailer link lives with the summary text above.)
    private var actionPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PillButton(title: "Where to Watch", systemImage: "play.rectangle", style: .outlined) {
                    showWhereToWatch = true
                }
                if movie.mediaKind != "tv" {
                    PillButton(title: "Showtimes", systemImage: "ticket", style: .outlined) {
                        showShowtimes = true
                    }
                }
                PillButton(title: "Recommend", systemImage: "paperplane", style: .outlined) {
                    showSendRec = true
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
    }

    private var scoresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scores").font(.title3.weight(.bold))

            HStack(alignment: .top, spacing: 12) {
                // Empty = an invitation: the dashed circle carries a gold +
                // and the whole column starts the rank flow.
                Button {
                    showLogFlow = true
                } label: {
                    scoreColumn(
                        badge: myItem.map { ScoreBadge(score: $0.score, size: 60) },
                        emptyIcon: "plus",
                        emptyTint: Theme.marquee,
                        title: "Your Cini Rating",
                        subtitle: myItem.map { "#\($0.rank) on your Watched list" } ?? "Tap to rank it"
                    )
                }
                .buttonStyle(.plain)
                .disabled(myItem != nil)

                scoreColumn(
                    badge: friendAverage.map { ScoreBadge(score: $0, count: friends.count, size: 60) },
                    emptyIcon: "person.2",
                    title: "Friend Score",
                    subtitle: friends.isEmpty ? "No friends have ranked it yet"
                                              : "What your friends think"
                )
                scoreColumn(
                    badge: community.map { ScoreBadge(score: $0.avgScore, count: $0.ratingCount, size: 60) },
                    emptyIcon: "sparkles",
                    title: "Average Score",
                    subtitle: community == nil ? "Be the first on Cini to rank it"
                                               : "What all of Cini thinks"
                )
            }
        }
        .padding(.horizontal, 16)
    }

    private var friendAverage: Double? {
        guard !friends.isEmpty else { return nil }
        return (friends.map(\.score).reduce(0, +) / Double(friends.count) * 10).rounded() / 10
    }

    private func scoreColumn(badge: ScoreBadge?, emptyIcon: String,
                             emptyTint: Color = Theme.gray,
                             title: String, subtitle: String) -> some View {
        VStack(spacing: 6) {
            if let badge {
                badge
            } else {
                ZStack {
                    Circle().strokeBorder(
                        emptyTint.opacity(emptyTint == Theme.gray ? 0.45 : 0.8),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4]))
                    Image(systemName: emptyIcon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(emptyTint.opacity(emptyTint == Theme.gray ? 0.6 : 1))
                }
                .frame(width: 60, height: 60)
            }
            Text(title).font(.caption.weight(.bold))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(subtitle).font(.caption2).foregroundStyle(Theme.gray).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    /// Summary — the overview, clamped to four lines with a "more"
    /// toggle, with the trailer link right where you decide to watch.
    @ViewBuilder
    private var summarySection: some View {
        let overview = movie.overview?.isEmpty == false ? movie.overview : nil
        if overview != nil || trailerURL != nil {
            VStack(alignment: .leading, spacing: 8) {
                if let overview {
                    Text(overview)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink.opacity(0.9))
                        .lineLimit(summaryExpanded ? nil : 4)
                    if overview.count > 220 {
                        Button(summaryExpanded ? "Less" : "More") {
                            withAnimation(.snappy) { summaryExpanded.toggle() }
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .buttonStyle(.plain)
                    }
                }
                if let trailerURL {
                    Button {
                        UIApplication.shared.open(trailerURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.circle.fill")
                            Text("Watch trailer")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Letterboxd-style cast list: photo, name, character, six at a time.
    @ViewBuilder
    private var castSection: some View {
        if !cast.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Cast").font(.title3.weight(.bold))
                    .padding(.bottom, 8)
                ForEach(cast.prefix(showAllCast ? 30 : 6)) { member in
                    HStack(spacing: 12) {
                        CachedAsyncImage(url: member.photoURL) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Rectangle().fill(Theme.gray.opacity(0.2))
                                .overlay(Image(systemName: "person")
                                    .font(.caption)
                                    .foregroundStyle(Theme.gray))
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.name).font(.subheadline.weight(.semibold))
                            if let character = member.character, !character.isEmpty {
                                Text(character).font(.caption).foregroundStyle(Theme.gray)
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 6)
                    Divider().overlay(Theme.hairline)
                }
                if cast.count > 6 {
                    Button {
                        withAnimation(.snappy) { showAllCast.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Text(showAllCast ? "Show fewer" : "Show \(min(cast.count, 30) - 6) more")
                            Image(systemName: showAllCast ? "chevron.up" : "chevron.down")
                                .font(.caption)
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    /// Details — studio, country, language, genres, release date.
    @ViewBuilder
    private var detailsSection: some View {
        if let extended {
            let facts: [(String, String)] = [
                ("Studio", extended.studios.prefix(2).joined(separator: ", ")),
                ("Country", extended.countries.prefix(2).joined(separator: ", ")),
                ("Language", extended.languages.prefix(3).joined(separator: ", ")),
                ("Genres", movie.genres.joined(separator: ", ")),
                ("Release", formattedRelease(extended.releaseDate) ?? ""),
            ].filter { !$0.1.isEmpty }
            if !facts.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Details").font(.title3.weight(.bold))
                        .padding(.bottom, 2)
                    ForEach(facts, id: \.0) { fact in
                        HStack(alignment: .top, spacing: 12) {
                            Text(fact.0)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Theme.gray)
                                .frame(width: 76, alignment: .leading)
                            Text(fact.1)
                                .font(.subheadline)
                                .foregroundStyle(Theme.ink.opacity(0.9))
                            Spacer()
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func formattedRelease(_ raw: String?) -> String? {
        guard let raw, let date = DateFormatter.posixDay.date(from: raw) else { return raw }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    private var performancesSection: some View {
        Group {
            if !performances.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Top Performances").font(.title3.weight(.bold))
                        .padding(.horizontal, 16)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(performances, id: \.tmdbPersonId) { performance in
                                VStack(alignment: .leading, spacing: 6) {
                                    CachedAsyncImage(url: performance.photoURL) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Rectangle().fill(Theme.gray.opacity(0.2))
                                            .overlay(Image(systemName: "person").foregroundStyle(Theme.gray))
                                    }
                                    .frame(width: 140, height: 140)
                                    .clipShape(RoundedRectangle(cornerRadius: 12))
                                    Text(performance.personName).font(.subheadline.weight(.semibold))
                                    Text("\(performance.count) recommended")
                                        .font(.caption)
                                        .foregroundStyle(Theme.gray)
                                }
                                .frame(width: 140)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
            }
        }
    }

    /// Beli's breakdown: big colored average + count on the left, the
    /// distribution on the right with just the 0.0 / 10.0 endpoints.
    private var histogramSection: some View {
        Group {
            if !histogram.isEmpty, let community {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Ratings Breakdown").font(.title3.weight(.bold))
                    HStack(alignment: .center, spacing: 20) {
                        VStack(spacing: 2) {
                            Text(community.avgScore.formatted(.number.precision(.fractionLength(1))))
                                .font(.system(size: 44, weight: .bold, design: .rounded))
                                .foregroundStyle(Theme.scoreColor(community.avgScore))
                            Text(ratingCountLabel(community.ratingCount))
                                .font(.subheadline)
                                .foregroundStyle(Theme.gray)
                        }
                        VStack(spacing: 6) {
                            let maxN = histogram.map(\.n).max() ?? 1
                            HStack(alignment: .bottom, spacing: 4) {
                                ForEach(0..<11, id: \.self) { floor in
                                    let n = histogram.first { $0.bucketFloor == floor }?.n ?? 0
                                    RoundedRectangle(cornerRadius: 2.5)
                                        .fill(Theme.marquee.opacity(n == 0 ? 0.18 : 0.9))
                                        .frame(height: max(3, 84 * CGFloat(n) / CGFloat(maxN)))
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .frame(height: 84, alignment: .bottom)
                            HStack {
                                Text("0.0")
                                Spacer()
                                Text("10.0")
                            }
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    /// Everything YOU attached while ranking: notes, performances,
    /// labels, watch date and company.
    @ViewBuilder
    private var yourDetailsSection: some View {
        if let myDetails {
            VStack(alignment: .leading, spacing: 12) {
                Text("Your Details").font(.title3.weight(.bold))

                if let note = myDetails.note {
                    detailRow(icon: "square.and.pencil", title: "Notes") {
                        Text(note).font(.subheadline)
                    }
                }
                if let personal = myDetails.personalNote {
                    detailRow(icon: "eye.slash", title: "Personal notes (only you)") {
                        Text(personal).font(.subheadline)
                    }
                }
                if !myDetails.performances.isEmpty {
                    detailRow(icon: "star", title: "Favorite performances") {
                        Text(myDetails.performances.map(\.name).joined(separator: ", "))
                            .font(.subheadline)
                    }
                }
                if !myDetails.labels.isEmpty {
                    detailRow(icon: "tag", title: "Labels") {
                        Text(myDetails.labels.joined(separator: " · "))
                            .font(.subheadline)
                            .foregroundStyle(Theme.marquee)
                    }
                }
                if myDetails.watchDate != nil || !myDetails.watchedWith.isEmpty
                    || myDetails.watchedWhere != nil {
                    detailRow(icon: "calendar", title: "Watched") {
                        Text(watchedLine(myDetails))
                            .font(.subheadline)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func watchedLine(_ details: SupabaseService.MyMovieDetails) -> String {
        var parts: [String] = []
        if let date = details.watchDate { parts.append(date) }
        if let location = details.watchedWhere {
            parts.append(location == "theater" ? "In theaters" : "At home")
        }
        if !details.watchedWith.isEmpty {
            parts.append("with " + details.watchedWith.map { "@" + $0 }.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func detailRow(icon: String, title: String,
                           @ViewBuilder content: () -> some View) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.subheadline)
                .foregroundStyle(Theme.marquee)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(Theme.gray)
                content()
            }
            Spacer()
        }
    }

    private func ratingCountLabel(_ count: Int) -> String {
        count >= 1000 ? "\(count / 1000)k ratings"
                      : "\(count) rating\(count == 1 ? "" : "s")"
    }

    /// "What people think" — Friends (everyone you follow who ranked it)
    /// and Everyone (any member's rating that came with a public note).
    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What people think").font(.title3.weight(.bold))

            // Same underline tabs as Your Lists.
            HStack(spacing: 22) {
                ForEach(PeopleTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.snappy) { peopleTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            Text(tab.rawValue)
                                .font(.subheadline.weight(peopleTab == tab ? .bold : .regular))
                                .foregroundStyle(peopleTab == tab ? Theme.ink : Theme.gray)
                            Rectangle()
                                .fill(peopleTab == tab ? Theme.ink : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }

            switch peopleTab {
            case .friends:
                if friends.isEmpty {
                    Text("None of your friends have ranked this yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                }
                ForEach(friends) { friend in
                    FriendThinkRow(friend: friend) { tapped in
                        memberTarget = MemberRef(id: tapped.userId, username: tapped.username)
                    }
                    Divider()
                }
            case .everyone:
                Text("Ratings that came with a note show here.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                if publicNotes.isEmpty {
                    if publicNotesLoaded {
                        Text("No notes from the community yet — rank it and say something.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .padding(.vertical, 8)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                }
                ForEach(publicNotes) { row in
                    publicNoteRow(row)
                    Divider()
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func publicNoteRow(_ row: PublicNoteRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    memberTarget = MemberRef(id: row.userId, username: row.username)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: row.avatarUrl.flatMap(URL.init), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.displayName?.isEmpty == false ? row.displayName! : row.username)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("@\(row.username)").font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                }
                .buttonStyle(.plain)
                Spacer()
                ScoreBadge(score: row.score, size: 44)
            }

            (Text("Notes: ").bold() + Text(row.note))
                .font(.subheadline)

            // Heart + comment, exactly where the feed puts them.
            HStack(spacing: 18) {
                Button {
                    toggleHeart(on: row)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: row.likedByMe ? "heart.fill" : "heart")
                            .foregroundStyle(row.likedByMe ? .red : Theme.ink)
                        if row.likeCount > 0 {
                            Text("\(row.likeCount)").font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                }
                Button {
                    if let eventId = row.eventId {
                        commentsTarget = CommentsTarget(id: eventId)
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bubble.right")
                        if row.commentCount > 0 {
                            Text("\(row.commentCount)").font(.caption).foregroundStyle(Theme.gray)
                        }
                    }
                }
                Spacer()
                Text(row.rankedAt.formatted(.dateTime.month(.wide).year()))
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            .font(.body)
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)
            .disabled(row.eventId == nil)
        }
        .padding(.vertical, 6)
    }

    /// Optimistic heart, reverted if the call fails.
    private func toggleHeart(on row: PublicNoteRow) {
        guard let eventId = row.eventId,
              let index = publicNotes.firstIndex(where: { $0.id == row.id }) else { return }
        let wasLiked = publicNotes[index].likedByMe
        publicNotes[index].likedByMe.toggle()
        publicNotes[index].likeCount += wasLiked ? -1 : 1
        Task {
            do { try await SupabaseService.shared.toggleLike(eventID: eventId) }
            catch {
                if let i = publicNotes.firstIndex(where: { $0.id == row.id }) {
                    publicNotes[i].likedByMe = wasLiked
                    publicNotes[i].likeCount += wasLiked ? 1 : -1
                }
            }
        }
    }

    // MARK: Data

    private func loadEverything() async {
        store.cache(movie)
        async let detail = TMDBService.shared.details(for: movie.tmdbID)
        async let providersTask = TMDBService.shared.watchProviders(for: movie.tmdbID)
        async let trailerTask = TMDBService.shared.trailerURL(for: movie.tmdbID)
        async let communityTask = SupabaseService.shared.communityScore(movieID: movie.tmdbID)
        async let friendsTask = SupabaseService.shared.friendScores(movieID: movie.tmdbID)
        async let histogramTask = SupabaseService.shared.scoreHistogram(movieID: movie.tmdbID)
        async let performancesTask = SupabaseService.shared.topPerformances(movieID: movie.tmdbID)
        async let labelsTask = SupabaseService.shared.movieTopLabels(movieID: movie.tmdbID)
        async let myDetailsTask = SupabaseService.shared.myMovieDetails(movieID: movie.tmdbID)
        async let keywordsTask = TMDBService.shared.keywords(for: movie.tmdbID)
        async let castTask = TMDBService.shared.cast(for: movie.tmdbID)
        async let extendedTask = TMDBService.shared.extendedDetails(for: movie.tmdbID)
        async let publicNotesTask = SupabaseService.shared.publicNotes(movieID: movie.tmdbID)

        if let detailed = try? await detail {
            var enriched = detailed
            if let providers = try? await providersTask {
                enriched.streamingOn = providers.streamingNames
                self.providers = providers
            }
            movie = enriched
            store.cache(enriched)
        }
        myDetails = await myDetailsTask
        let communityLabels = (try? await labelsTask) ?? []
        tags = communityLabels.isEmpty ? ((try? await keywordsTask) ?? []) : communityLabels
        trailerURL = try? await trailerTask
        community = try? await communityTask
        friends = (try? await friendsTask) ?? []
        histogram = (try? await histogramTask) ?? []
        performances = (try? await performancesTask) ?? []
        cast = (try? await castTask) ?? []
        extended = try? await extendedTask
        publicNotes = (try? await publicNotesTask) ?? []
        publicNotesLoaded = true
    }
}
