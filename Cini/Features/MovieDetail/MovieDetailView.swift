import SwiftUI
import RankingEngine
import UserNotifications

/// Movie detail — mirrors Beli's restaurant page: backdrop hero, serif title,
/// community score, "Rank again", tags, metadata, social proof, action pills,
/// the three-circle Scores section, Top Performances, ratings histogram, and
/// "What your friends think".
struct MovieDetailView: View {
    @State var movie: Movie

    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @Environment(AppSession.self) private var session

    @State private var showUnlocks = false
    /// The aggregated "what all of Cini thinks" score is a referral-unlock.
    private var scoresLocked: Bool { !session.isUnlocked("aggregate_scores") }

    @State private var community: CommunityScore?
    @State private var friends: [FriendScoreRow] = []
    @State private var friendsLoaded = false
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
    @State private var showRankAgainDialog = false
    @State private var showDeleteRatingConfirm = false
    @State private var showRewatchSheet = false
    @State private var showEditDetails = false
    @State private var showWhereToWatch = false
    @State private var showShowtimes = false
    @State private var showSendRec = false
    @State private var memberTarget: MemberRef?
    @State private var personTarget: CastMember?
    @State private var predicted: Double?
    @State private var scoreInfo: ScoreInfo?
    @State private var peopleTab: PeopleTab = .friends
    @State private var publicNotes: [PublicNoteRow] = []
    @State private var publicNotesLoaded = false
    @State private var blockCandidate: PublicNoteRow?
    @State private var commentsTarget: CommentsTarget?
    @State private var watchlistFriends: [WatchlistFriendRow] = []
    @State private var watchingFriends: [WatchingFriendRow] = []
    @State private var planContext: WatchPlanContext?
    @State private var showWantSheet = false
    @State private var showWatchingSheet = false
    @State private var premiereReminderOn = false
    /// Latest plan per friend for this title, to label the invite buttons.
    @State private var watchPlansByFriend: [UUID: WatchPlanRow] = [:]

    enum PeopleTab: String, CaseIterable {
        case friends = "Friends"
        case everyone = "Everyone"
    }

    struct CommentsTarget: Identifiable, Hashable {
        let id: UUID
        var context: CommentContext? = nil
        static func == (lhs: CommentsTarget, rhs: CommentsTarget) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Which score circle is being explained.
    enum ScoreInfo: String, Identifiable {
        case rec, friend, average
        var id: String { rawValue }
    }

    private var myItem: ScoredItem<Int>? { store.scoredItem(for: movie.tmdbID) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                hero
                tagRow
                metadataBlock
                friendsInterestRow
                summarySection
                actionPills
                // "Is it good?" leads, right after the act-now pills.
                scoresSection
                WatchingControl(movie: movie, info: extended)
                    .padding(.horizontal, 16)
                nextEpisodeRow
                histogramSection
                yourDetailsSection
                moreInfoSection
                performancesSection
                peopleSection
            }
            // Ask Cini opens context-aware: the page you're on is the
            // movie you're asking about.
            .onAppear { tabRouter.visibleMovie = movie }
            .onDisappear {
                if tabRouter.visibleMovie?.tmdbID == movie.tmdbID {
                    tabRouter.visibleMovie = nil
                }
            }
            .padding(.bottom, 32)
        }
        .nativeContentWidth()
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
        .sheet(item: $planContext) { ctx in
            PlanWatchSheet(context: ctx)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showWantSheet) { wantToWatchSheet }
        .sheet(isPresented: $showWatchingSheet) { watchingSheet }
        .sheet(isPresented: $showUnlocks) {
            UnlocksView()
        }
        // Pushed onto the nav stack so it gets a native back + swipe-back; a
        // tapped commenter pushes their profile on top.
        .navigationDestination(item: $commentsTarget) { target in
            CommentsSheet(eventID: target.id, context: target.context,
                          onOpenMember: { memberTarget = $0 },
                          onCommentCountChange: { newCount in
                              if let i = publicNotes.firstIndex(where: { $0.eventId == target.id }) {
                                  publicNotes[i].commentCount = newCount
                              }
                          })
        }
        .sheet(item: $scoreInfo) { info in
            ScoreInfoSheet(info: info)
                .presentationDetents([.height(300)])
                .presentationDragIndicator(.visible)
        }
        // Beli's "Rank again" menu: rerank, reorder, rewatch — or out.
        .confirmationDialog("Rank again", isPresented: $showRankAgainDialog) {
            Button("Rerank this movie") { showLogFlow = true }
            Button("Reorder within my list") {
                tabRouter.pendingReorder = true
                tabRouter.selection = .lists
            }
            Button("Log a rewatch") { showRewatchSheet = true }
            Button("Delete my rating", role: .destructive) {
                showDeleteRatingConfirm = true
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Delete your rating for \(movie.title)?", isPresented: $showDeleteRatingConfirm) {
            Button("Delete my rating", role: .destructive) {
                Task {
                    if await store.removeRanking(movieID: movie.tmdbID) {
                        Haptics.success()
                        ToastCenter.shared.show("Rating deleted")
                        myDetails = await SupabaseService.shared.myMovieDetails(movieID: movie.tmdbID)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It comes off your ranked list and your score clears. Notes and diary entries stay.")
        }
        // Blocking is heavy — always confirm before mutual invisibility.
        .alert(
            "Block @\(blockCandidate?.username ?? "")?",
            isPresented: Binding(get: { blockCandidate != nil },
                                 set: { if !$0 { blockCandidate = nil } }),
            presenting: blockCandidate
        ) { row in
            Button("Block @\(row.username)", role: .destructive) {
                Task {
                    do {
                        try await SupabaseService.shared.block(row.userId)
                        ToastCenter.shared.show("Blocked @\(row.username) — their content is hidden")
                        // Refresh only on success — a failed reload must
                        // not wipe the wall.
                        if let fresh = try? await SupabaseService.shared
                            .publicNotes(movieID: movie.tmdbID) {
                            publicNotes = fresh
                        }
                    } catch {
                        ToastCenter.shared.saveFailed()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You won't see each other's rankings, notes, or activity.")
        }
        .sheet(isPresented: $showEditDetails) {
            EditDetailsSheet(movie: movie, details: myDetails, cast: cast,
                             isRanked: myItem != nil) {
                Task { myDetails = await SupabaseService.shared.myMovieDetails(movieID: movie.tmdbID) }
            }
        }
        .sheet(isPresented: $showRewatchSheet) {
            RewatchSheet(movie: movie) {
                Task { myDetails = await SupabaseService.shared.myMovieDetails(movieID: movie.tmdbID) }
            }
            .presentationDetents([.height(420)])
            .presentationDragIndicator(.visible)
        }
        .navigationDestination(item: $personTarget) { member in
            PersonScreen(member: member, originTitle: movie.title)
        }
        .navigationDestination(item: $memberTarget) { member in
            MemberProfileView(userID: member.id, username: member.username)
        }
        .task { await loadEverything() }
        // Pull-to-refresh, like the feed and profiles — re-pull scores,
        // friends, your details and availability for this title.
        .refreshable { await loadEverything() }
    }

    // MARK: Sections

    @State private var heroAppeared = false

    /// Beli-style hero: the artwork fades into the page so the title,
    /// score, and CTAs sit ON it and stay perfectly readable.
    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            Color.black
            // The artwork lives in an overlay so its bitmap size can never
            // leak into layout — scaledToFill alone reports the image's
            // intrinsic width and inflates the whole page wider than the
            // screen (titles and pills clipped at both edges).
            Color.clear
                .frame(height: 300)
                .frame(maxWidth: .infinity)
                .overlay {
                    CachedAsyncImage(url: movie.backdropURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(Theme.gray.opacity(0.2))
                    }
                }
                .clipped()
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
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
                    .shadow(color: .black.opacity(0.5), radius: 6, y: 1)

                HStack(spacing: 10) {
                    if let community, !scoresLocked {
                        ScoreChip(score: community.avgScore)
                        Text("(\(community.ratingCount.formatted()) ratings)")
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    Spacer()
                    if let myItem {
                        // Already ranked: YOUR score lives on the artwork,
                        // since the circles below lead with Rec Score.
                        ScoreBadge(score: myItem.score, size: 40)
                    }
                    if myItem != nil {
                        // Already ranked: Beli's "Rank again" pill + check.
                        Button {
                            showRankAgainDialog = true
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
                  movie.director.map { movie.mediaKind == "tv" ? "By \($0)" : "Dir. \($0)" }]
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
                PillButton(title: "Watch", systemImage: "play.rectangle", style: .outlined) {
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

    /// Rec Score always leads; tapping any circle explains what it means.
    private var scoresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scores").font(.title3.weight(.bold))

            HStack(alignment: .top, spacing: 12) {
                Button {
                    scoreInfo = .rec
                } label: {
                    scoreColumn(
                        badge: predicted.map { ScoreBadge(score: $0, size: 60) },
                        emptyIcon: "wand.and.stars",
                        emptyTint: Theme.marquee,
                        title: "Rec Score",
                        subtitle: predicted == nil
                            ? "Rank a few movies to unlock"
                            : "How much we think you'll like it"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    scoreInfo = .friend
                } label: {
                    scoreColumn(
                        badge: friendAverage.map { ScoreBadge(score: $0, count: friends.count, size: 60) },
                        emptyIcon: "person.2",
                        title: "Friend Score",
                        subtitle: friends.isEmpty ? "No friends have ranked it yet"
                                                  : "What your friends think"
                    )
                }
                .buttonStyle(.plain)

                Button {
                    if scoresLocked { showUnlocks = true } else { scoreInfo = .average }
                } label: {
                    scoreColumn(
                        badge: scoresLocked ? nil : community.map { ScoreBadge(score: $0.avgScore, count: $0.ratingCount, size: 60) },
                        emptyIcon: scoresLocked ? "lock.fill" : "sparkles",
                        emptyTint: scoresLocked ? Theme.marquee : Theme.gray,
                        title: "Average Score",
                        subtitle: scoresLocked ? "Invite a friend to unlock"
                                  : (community == nil ? "Be the first on Cini to rank it"
                                                      : "What all of Cini thinks")
                    )
                }
                .buttonStyle(.plain)
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

    /// Summary — the overview, clamped to two lines with a "more"
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
                        .lineLimit(summaryExpanded ? nil : 2)
                    // ~2 lines of subheadline ≈ 110 chars; longer → offer "More".
                    if overview.count > 110 {
                        Button(summaryExpanded ? "Less" : "More") {
                            Haptics.tap()
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

    /// Cast + Details live behind one quiet disclosure so the page stays
    /// focused on scores and people until you ask for the deep facts.
    @State private var showMoreInfo = false

    @ViewBuilder
    private var moreInfoSection: some View {
        if !cast.isEmpty || extended != nil {
            VStack(alignment: .leading, spacing: 18) {
                Button {
                    Haptics.tap()
                    withAnimation(.snappy) { showMoreInfo.toggle() }
                } label: {
                    HStack {
                        Text("Cast & Details")
                            .font(.title3.weight(.bold))
                            .foregroundStyle(Theme.ink)
                        Spacer()
                        Image(systemName: showMoreInfo ? "chevron.up" : "chevron.down")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.gray)
                    }
                    .padding(.horizontal, 16)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showMoreInfo {
                    castSection
                    detailsSection
                }
            }
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
                    Button {
                        personTarget = member
                    } label: {
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
                                    .foregroundStyle(Theme.ink)
                                if let character = member.character, !character.isEmpty {
                                    Text(character).font(.caption).foregroundStyle(Theme.gray)
                                }
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Theme.hairline)
                }
                if cast.count > 6 {
                    Button {
                        Haptics.tap()
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
                                // Anywhere a person appears, they're a door
                                // to their page.
                                Button {
                                    personTarget = CastMember(
                                        id: performance.tmdbPersonId,
                                        name: performance.personName,
                                        character: nil,
                                        profilePath: performance.profilePath)
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        CachedAsyncImage(url: performance.photoURL) { image in
                                            image.resizable().scaledToFill()
                                        } placeholder: {
                                            Rectangle().fill(Theme.gray.opacity(0.2))
                                                .overlay(Image(systemName: "person").foregroundStyle(Theme.gray))
                                        }
                                        .frame(width: 140, height: 140)
                                        .clipShape(RoundedRectangle(cornerRadius: 12))
                                        Text(performance.personName)
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(Theme.ink)
                                        Text("\(performance.count) recommended")
                                            .font(.caption)
                                            .foregroundStyle(Theme.gray)
                                    }
                                    .frame(width: 140)
                                }
                                .buttonStyle(.plain)
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
            if !histogram.isEmpty, let community, !scoresLocked {
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

    /// Everything YOU attached while ranking — and it's never read-only:
    /// the pencil opens the same editors the rank flow uses.
    @ViewBuilder
    private var yourDetailsSection: some View {
        // Always present — notes, performances, and watch history work
        // whether or not the movie is ranked yet (imports land here too).
        VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Your Details").font(.title3.weight(.bold))
                    Spacer()
                    Button {
                        showEditDetails = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "pencil")
                            Text(myDetails == nil ? "Add" : "Edit")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if myDetails == nil {
                    Text("Notes, who you watched with, favorite performances — add them anytime.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                if let myDetails {

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
        }
        .padding(.horizontal, 16)
    }

    private func watchedLine(_ details: SupabaseService.MyMovieDetails) -> String {
        var parts: [String] = []
        if details.watchCount > 1 { parts.append("\(details.watchCount)× watched") }
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
                            HStack(spacing: 5) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(peopleTab == tab ? .bold : .regular))
                                    .foregroundStyle(peopleTab == tab ? Theme.ink : Theme.gray)
                                // Review count — same capsule as the
                                // Pending badge in Your Lists.
                                if tab == .everyone && !publicNotes.isEmpty {
                                    Text("\(publicNotes.count)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.background)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.marquee))
                                }
                            }
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
                if !friendsLoaded {
                    ListSkeleton(rows: 3)
                } else if friends.isEmpty {
                    Text("None of your friends have ranked this yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                }
                ForEach(friends) { friend in
                    // Reactable feed-style card when the ranking has an event
                    // (CIN-40); older rankings without one fall back to the row.
                    if let event = feedEvent(from: friend) {
                        FeedCard(
                            event: event,
                            initiallyLiked: friend.likedByMe,
                            onOpenMember: { memberTarget = $0 },
                            onOpenComments: { ev, ctx in
                                commentsTarget = CommentsTarget(id: ev.id, context: ctx)
                            }
                        )
                    } else {
                        FriendThinkRow(friend: friend) { tapped in
                            memberTarget = MemberRef(id: tapped.userId, username: tapped.username)
                        }
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
                        ListSkeleton(rows: 3)
                            .padding(.vertical, 8)
                    }
                }
                ForEach(publicNotes) { row in
                    if let event = feedEvent(from: row) {
                        // Same card as the feed, so people can like/comment here
                        // too (CIN-27). Report/block ride along for moderation.
                        FeedCard(
                            event: event,
                            initiallyLiked: row.likedByMe,
                            onOpenMember: { memberTarget = $0 },
                            onOpenComments: { ev, ctx in
                                commentsTarget = CommentsTarget(id: ev.id, context: ctx)
                            },
                            onReport: {
                                Task {
                                    let ok = await SupabaseService.shared.report(
                                        kind: "note", subjectID: "\(row.userId)/\(movie.tmdbID)")
                                    if ok { ToastCenter.shared.show("Reported — we'll review it") }
                                    else { ToastCenter.shared.saveFailed() }
                                }
                            },
                            onBlock: { blockCandidate = row }
                        )
                        Divider()
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    /// Same as above but for a friend's ranking, so the Friends wall is also
    /// reactable and shows your own ranking (CIN-40).
    private func feedEvent(from friend: FriendScoreRow) -> FeedEventRow? {
        guard let eventId = friend.eventId else { return nil }
        let row = MovieRow(
            tmdbId: movie.tmdbID, mediaKind: movie.mediaKind, title: movie.title,
            releaseYear: movie.releaseYear, posterPath: movie.posterPath,
            backdropPath: movie.backdropPath, genres: movie.genres,
            certification: movie.certification, runtimeMinutes: movie.runtimeMinutes,
            director: movie.director, overview: movie.overview)
        return FeedEventRow(
            id: eventId, userId: friend.userId, eventType: "ranked",
            movieId: movie.tmdbID, createdAt: friend.rankedAt,
            payload: .init(score: friend.score),
            profiles: .init(username: friend.username, displayName: friend.displayName,
                            avatarUrl: friend.avatarUrl),
            movies: row,
            likes: [.init(count: friend.likeCount)],
            comments: [.init(count: friend.commentCount)],
            note: friend.note,
            noteContainsSpoilers: friend.containsSpoilers ?? false)
    }

    /// Build a feed-style event from a public note so the "What people think"
    /// wall renders with the same FeedCard as the feed (CIN-27).
    private func feedEvent(from note: PublicNoteRow) -> FeedEventRow? {
        guard let eventId = note.eventId else { return nil }
        let row = MovieRow(
            tmdbId: movie.tmdbID, mediaKind: movie.mediaKind, title: movie.title,
            releaseYear: movie.releaseYear, posterPath: movie.posterPath,
            backdropPath: movie.backdropPath, genres: movie.genres,
            certification: movie.certification, runtimeMinutes: movie.runtimeMinutes,
            director: movie.director, overview: movie.overview)
        return FeedEventRow(
            id: eventId, userId: note.userId, eventType: "ranked",
            movieId: movie.tmdbID, createdAt: note.rankedAt,
            payload: .init(score: note.score),
            profiles: .init(username: note.username, displayName: note.displayName,
                            avatarUrl: note.avatarUrl),
            movies: row,
            likes: [.init(count: note.likeCount)],
            comments: [.init(count: note.commentCount)],
            note: note.note,
            noteContainsSpoilers: note.containsSpoilers ?? false)
    }

    // MARK: Data

    private func loadWatchPlans(_ movieID: Int) async {
        let plans = await SupabaseService.shared.watchPlans(movieID: movieID)
        let me = SupabaseService.shared.currentUserID
        var map: [UUID: WatchPlanRow] = [:]
        for plan in plans {   // newest-first, so first seen per friend wins
            let other = plan.proposerId == me ? plan.inviteeId : plan.proposerId
            if map[other] == nil { map[other] = plan }
        }
        watchPlansByFriend = map
    }

    /// The invite button's label/style for a friend, given any existing plan.
    private func planButtonState(for friendID: UUID) -> (label: String, filled: Bool) {
        guard let plan = watchPlansByFriend[friendID] else { return ("Invite", true) }
        let me = SupabaseService.shared.currentUserID
        switch plan.status {
        case "accepted": return ("Planned ✓", false)
        case "proposed": return plan.proposerId == me ? ("Pending", false) : ("Respond", true)
        default:         return ("Invite", true)   // declined → can re-invite
        }
    }

    /// For ongoing shows: when the next episode (or season premiere) airs.
    @ViewBuilder
    private var nextEpisodeRow: some View {
        if movie.mediaKind == "tv",
           let ext = extended,
           let raw = ext.nextEpisodeAirDate,
           let date = DateFormatter.posixDay.date(from: raw),
           date >= Calendar.current.startOfDay(for: Date()) {
            HStack(spacing: 8) {
                Image(systemName: "calendar.badge.clock").foregroundStyle(Theme.marquee)
                Text(nextEpisodeText(ext, date))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Button {
                    Task { await togglePremiereReminder(date: date, label: nextEpisodeText(ext, date)) }
                } label: {
                    Label(premiereReminderOn ? "Reminder on" : "Remind me",
                          systemImage: premiereReminderOn ? "bell.fill" : "bell")
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .task(id: movie.tmdbID) { premiereReminderOn = await hasPremiereReminder() }
        }
    }

    private func reminderID() -> String { "premiere-\(movie.tmdbID)" }

    private func hasPremiereReminder() async -> Bool {
        let pending = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return pending.contains { $0.identifier == reminderID() }
    }

    /// Schedule (or cancel) a local notification on the morning the next
    /// episode/season airs — no server needed.
    private func togglePremiereReminder(date: Date, label: String) async {
        let center = UNUserNotificationCenter.current()
        if premiereReminderOn {
            center.removePendingNotificationRequests(withIdentifiers: [reminderID()])
            premiereReminderOn = false
            ToastCenter.shared.show("Reminder removed")
            return
        }
        guard await PushManager.request() else {
            ToastCenter.shared.show("Turn on notifications in Settings to get reminders.")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = movie.title
        content.body = "\(label) today 📺"
        content.sound = .default
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        comps.hour = 9
        // A non-repeating calendar trigger in the past never fires — if 9am on
        // the air date has already passed (it airs today), fire a minute out so
        // "Reminder set" isn't an empty promise.
        let trigger: UNNotificationTrigger
        if let fireAt = Calendar.current.date(from: comps), fireAt <= Date() {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)
        } else {
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        }
        do {
            try await center.add(UNNotificationRequest(identifier: reminderID(),
                                                       content: content, trigger: trigger))
            premiereReminderOn = true
            ToastCenter.shared.show("Reminder set for \(date.formatted(.dateTime.month(.abbreviated).day()))")
        } catch {
            ToastCenter.shared.saveFailed()
        }
    }

    private func nextEpisodeText(_ ext: TMDBService.ExtendedDetails, _ date: Date) -> String {
        let when = date.formatted(.dateTime.month(.abbreviated).day())
        if (ext.nextEpisodeNumber ?? 0) == 1, let s = ext.nextEpisodeSeason {
            return "Season \(s) premieres \(when)"
        }
        if let s = ext.nextEpisodeSeason, let e = ext.nextEpisodeNumber {
            return "Next: S\(s) · E\(e) airs \(when)"
        }
        return "Next episode airs \(when)"
    }

    // MARK: Beli-style "friends interested" rows + popups

    /// Compact rows high on the page: overlapping avatars + "N friends are
    /// watching" / "N friends want to watch", each tappable to a popup list.
    @ViewBuilder
    private var friendsInterestRow: some View {
        if !watchlistFriends.isEmpty || !watchingFriends.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                if !watchingFriends.isEmpty {
                    interestButton(
                        avatars: watchingFriends.map { ($0.avatarUrl, preferredName($0.displayName, $0.username) ?? $0.username) },
                        text: countText(watchingFriends.count, "is watching", "are watching")
                    ) { showWatchingSheet = true }
                }
                if !watchlistFriends.isEmpty {
                    interestButton(
                        avatars: watchlistFriends.map { ($0.avatarUrl, preferredName($0.displayName, $0.username) ?? $0.username) },
                        text: countText(watchlistFriends.count, "wants to watch", "want to watch")
                    ) { showWantSheet = true }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func countText(_ n: Int, _ singularVerb: String, _ pluralVerb: String) -> String {
        "\(n) \(n == 1 ? "friend \(singularVerb)" : "friends \(pluralVerb)")"
    }

    private func interestButton(avatars: [(String?, String)], text: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HStack(spacing: -10) {
                    ForEach(Array(avatars.prefix(3).enumerated()), id: \.offset) { _, a in
                        AvatarView(url: a.0.flatMap { URL(string: $0) }, size: 28, name: a.1)
                            .overlay(Circle().strokeBorder(Theme.background, lineWidth: 2))
                    }
                }
                Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.gray)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Popup: friends who want to watch — invite one to watch together.
    private var wantToWatchSheet: some View {
        NavigationStack {
            List {
                ForEach(watchlistFriends) { friend in
                    HStack(spacing: 12) {
                        Button {
                            openMember(friend.userId, friend.username, from: $showWantSheet)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: friend.avatarUrl.flatMap { URL(string: $0) }, size: 40,
                                           name: preferredName(friend.displayName, friend.username))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(firstName(friend.displayName, friend.username) ?? friend.username)
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text("@\(friend.username)").font(.caption).foregroundStyle(Theme.gray)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        let state = planButtonState(for: friend.userId)
                        Button {
                            Haptics.tap()
                            openPlan(with: friend.userId, username: friend.username, from: $showWantSheet)
                        } label: {
                            Text(state.label)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(state.filled ? Theme.background : Theme.marquee)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Capsule().fill(state.filled ? Theme.marquee : .clear))
                                .overlay(Capsule().strokeBorder(state.filled ? .clear : Theme.marquee.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain).background(Theme.background)
            .navigationTitle("Want to watch").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showWantSheet = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// Popup: friends currently watching — their progress, invite to watch together.
    private var watchingSheet: some View {
        NavigationStack {
            List {
                ForEach(watchingFriends) { friend in
                    HStack(spacing: 12) {
                        Button {
                            openMember(friend.userId, friend.username, from: $showWatchingSheet)
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: friend.avatarUrl.flatMap { URL(string: $0) }, size: 40,
                                           name: preferredName(friend.displayName, friend.username))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(firstName(friend.displayName, friend.username) ?? friend.username)
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text(friend.caughtUp ? "All caught up"
                                         : (episodeLabel(season: friend.season, episode: friend.episode) ?? "Watching now"))
                                        .font(.caption).foregroundStyle(friend.caughtUp ? Theme.scoreGreen : Theme.gray)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Spacer()
                        let state = planButtonState(for: friend.userId)
                        Button {
                            Haptics.tap()
                            openPlan(with: friend.userId, username: friend.username, from: $showWatchingSheet)
                        } label: {
                            Text(state.label).font(.subheadline.weight(.semibold))
                                .foregroundStyle(state.filled ? Theme.background : Theme.marquee)
                                .padding(.horizontal, 16).padding(.vertical, 8)
                                .background(Capsule().fill(state.filled ? Theme.marquee : .clear))
                                .overlay(Capsule().strokeBorder(state.filled ? .clear : Theme.marquee.opacity(0.6)))
                        }
                        .buttonStyle(.plain)
                    }
                    .listRowBackground(Theme.background)
                }
            }
            .listStyle(.plain).background(Theme.background)
            .navigationTitle("Watching now").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { showWatchingSheet = false } } }
        }
        .presentationDetents([.medium, .large])
    }

    /// Dismiss the list popup, then open the plan sheet (avoids two sheets racing).
    private func openPlan(with friendID: UUID, username: String, from flag: Binding<Bool>) {
        flag.wrappedValue = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            planContext = WatchPlanContext(movieID: movie.tmdbID,
                                           friend: MemberRef(id: friendID, username: username))
        }
    }

    /// Dismiss the list popup, then push that friend's profile.
    private func openMember(_ id: UUID, _ username: String, from flag: Binding<Bool>) {
        Haptics.tap()
        flag.wrappedValue = false
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            memberTarget = MemberRef(id: id, username: username)
        }
    }

    private func loadEverything() async {
        store.cache(movie)
        // Stable id captured before enrichment can reassign `movie` — the Rec
        // Score must be keyed by the SAME id the lists use (negative for TV),
        // or the page and the list disagree.
        let pid = movie.tmdbID
        async let detail = TMDBService.shared.details(for: movie.tmdbID)
        async let providersTask = TMDBService.shared.watchProviders(for: movie.tmdbID)
        async let trailerTask = TMDBService.shared.trailerURL(for: movie.tmdbID)
        // Community score, histogram, labels, performances: one round trip.
        async let statsTask = SupabaseService.shared.moviePageStats(movieID: movie.tmdbID)
        async let friendsTask = SupabaseService.shared.friendScores(movieID: movie.tmdbID)
        async let myDetailsTask = SupabaseService.shared.myMovieDetails(movieID: movie.tmdbID)
        async let keywordsTask = TMDBService.shared.keywords(for: movie.tmdbID)
        async let castTask = TMDBService.shared.cast(for: movie.tmdbID)
        async let extendedTask = TMDBService.shared.extendedDetails(for: movie.tmdbID)
        async let publicNotesTask = SupabaseService.shared.publicNotes(movieID: movie.tmdbID)
        async let predictedTask = SupabaseService.shared.predictedScores(movieIDs: [pid])

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
        let stats = await statsTask
        let communityLabels = stats?.labels ?? []
        tags = communityLabels.isEmpty ? ((try? await keywordsTask) ?? []) : communityLabels
        trailerURL = try? await trailerTask
        community = stats?.community
        friends = (try? await friendsTask) ?? []
        friendsLoaded = true
        watchlistFriends = (try? await SupabaseService.shared.watchlistFriends(movieID: pid)) ?? []
        watchingFriends = await SupabaseService.shared.watchingFriends(movieID: pid)
        await loadWatchPlans(pid)
        histogram = stats?.histogram ?? []
        performances = SupabaseService.tallyPerformances(stats?.performances ?? [])
        cast = (try? await castTask) ?? []
        extended = try? await extendedTask
        publicNotes = (try? await publicNotesTask) ?? []
        publicNotesLoaded = true
        let predictedMap = await predictedTask
        // Fold the fetch into the shared cache so the movie page and the lists
        // can't disagree, then resolve from that single source. Never blank a
        // score we already know (a cancelled/empty refetch shouldn't "lose" it).
        store.mergePredicted(predictedMap)
        if let p = store.predictedScores[pid] ?? predictedMap[pid] { predicted = p }
    }
}

// MARK: - Score explainers

/// Small modal that demystifies a score circle — what feeds it and why
/// it can differ from the others.
struct ScoreInfoSheet: View {
    let info: MovieDetailView.ScoreInfo

    private var icon: String {
        switch info {
        case .rec: "wand.and.stars"
        case .friend: "person.2"
        case .average: "sparkles"
        }
    }

    private var title: String {
        switch info {
        case .rec: "Rec Score"
        case .friend: "Friend Score"
        case .average: "Average Score"
        }
    }

    private var explanation: String {
        switch info {
        case .rec:
            return "How much we think YOU'LL like this title. It blends three signals: scores from friends whose taste matches yours (weighted by your taste match), how you've scored this title's genres before, and the Cini community average. It gets sharper with every movie you rank."
        case .friend:
            return "The average score from people you follow who've ranked this title. The small number shows how many friends it's based on — tap into What People Think below to see each one."
        case .average:
            return "The average score from everyone on Cini who's ranked this title. Titles with only a few ratings are pulled gently toward the middle, so one enthusiastic stranger can't define a movie."
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34))
                .foregroundStyle(Theme.marquee)
                .padding(.top, 28)
            Text(title).font(Theme.serif(26))
            Text(explanation)
                .font(.subheadline)
                .foregroundStyle(Theme.ink.opacity(0.85))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.background)
    }
}

// MARK: - Edit Your Details

/// Your Details is never read-only: the same card the rank flow uses,
/// seeded from what's saved, with Save in the toolbar.
struct EditDetailsSheet: View {
    let movie: Movie
    let details: SupabaseService.MyMovieDetails?
    let cast: [CastMember]
    /// Unranked movies have no ranking row: dates/places file into the
    /// diary instead, and watched-with (rankings-only) stays hidden.
    var isRanked: Bool = true
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = EnrichmentDraft()
    @State private var activeRow: EnrichmentCard.Row?
    @State private var saving = false
    @State private var seededDate: Date?

    var body: some View {
        NavigationStack {
            ScrollView {
                EnrichmentCard(movie: movie, draft: $draft,
                               isLocked: false, showsOkay: false, showsStealth: false,
                               showsWatchedWith: isRanked,
                               onOkay: {}, activeRow: $activeRow)
                    .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Your Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .bold()
                    .disabled(saving)
                }
            }
            .overlay {
                if let row = activeRow {
                    EnrichmentEditorOverlay(row: row, draft: $draft, cast: cast) {
                        activeRow = nil
                    }
                }
            }
            .onAppear { seed() }
        }
    }

    private func seed() {
        guard let details else { return }
        draft.notes = details.note ?? ""
        draft.notesContainSpoilers = details.noteContainsSpoilers
        draft.watchedWith = Set(details.watchedWithIDs)
        draft.watchedWhere = details.watchedWhere
        draft.watchDate = details.watchDate.flatMap { DateFormatter.posixDay.date(from: $0) }
        seededDate = draft.watchDate
        draft.cast = Set(details.performances.map { performance in
            // Prefer the live cast entry (carries the character name).
            cast.first { $0.id == performance.id }
                ?? CastMember(id: performance.id, name: performance.name,
                              character: nil, profilePath: performance.profilePath)
        })
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let supabase = SupabaseService.shared
        let body = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Track whether ANY write failed so we don't report false success and
        // silently lose the user's edits (the "silent contract drift" enemy).
        var failed = false
        func attempt(_ label: String, _ op: () async throws -> Void) async {
            do { try await op() }
            catch { failed = true; SupabaseService.logSwallowed(label, error) }
        }
        if body.isEmpty {
            if details?.note != nil {
                await attempt("edit_details.deleteNote") {
                    try await supabase.deleteNote(movieID: movie.tmdbID, isPrivate: false)
                }
            }
        } else {
            await attempt("edit_details.upsertNote") {
                try await supabase.upsertNote(movieID: movie.tmdbID, body: body,
                                              isPrivate: false,
                                              containsSpoilers: draft.notesContainSpoilers)
            }
        }
        if isRanked {
            await attempt("edit_details.updateRanking") {
                try await supabase.updateRanking(movieID: movie.tmdbID,
                                                 watchedWith: Array(draft.watchedWith),
                                                 watchDate: draft.watchDate,
                                                 watchedWhere: draft.watchedWhere)
            }
        } else if let date = draft.watchDate, date != seededDate {
            // No ranking row to hang the date on — it becomes a diary
            // entry instead (only when actually changed, no dupes).
            await attempt("edit_details.logWatch") {
                try await supabase.cacheMovie(movie)
                try await supabase.logWatch(movieID: movie.tmdbID, on: date,
                                            where: draft.watchedWhere)
            }
        }
        await attempt("edit_details.setPerformances") {
            try await supabase.setPerformances(movieID: movie.tmdbID, cast: Array(draft.cast))
        }
        FriendsCache.shared.warm()   // tag frequencies may have changed
        if failed {
            // Keep the sheet open so the edit isn't lost to a tap.
            ToastCenter.shared.saveFailed()
            return
        }
        Haptics.success()
        onSaved()
        dismiss()
    }
}
