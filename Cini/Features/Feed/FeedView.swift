import SwiftUI
import UserNotifications

struct FeedView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter

    @State private var events: [FeedEventRow] = []
    @State private var likedEventIDs: Set<UUID> = []
    @State private var feedLoaded = false
    @State private var unreadCount = 0
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var memberTarget: MemberRef?
    @State private var showImport = false
    @State private var showRankSheet = false
    @State private var showMenuImport = false
    @State private var showSettings = false
    @State private var showInviteSheet = false
    @State private var showLogoutConfirm = false

    var body: some View {
        NavigationStack {
            // Header, search, and the pill row stay frozen; only the
            // feed itself scrolls underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    searchBar
                    quickPills
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollView {
                    yourFeed
                        .padding(.horizontal, 16)
                }
                .refreshable { await loadFeed() }
            }
            .background(Theme.background)
            .task { await loadFeed() }
            // Tapped push notifications land here (cold launch included) —
            // consume on appear AND on change, since the tab stays alive.
            .onAppear { consumePush() }
            .onChange(of: tabRouter.pendingPushMovieID) { _, _ in consumePush() }
            .onChange(of: tabRouter.pendingPushMember) { _, _ in consumePush() }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
            .navigationDestination(item: $memberTarget) { member in
                MemberProfileView(userID: member.id, username: member.username)
            }
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showMenuImport) {
                LetterboxdImportView()
            }
            .navigationDestination(isPresented: $showSettings) {
                AccountSettingsView()
            }
            .sheet(isPresented: $showInviteSheet) {
                InviteSheet()
                    .presentationDetents([.medium])
            }
        }
    }

    // MARK: Header: serif wordmark + calendar / bell / hamburger

    private var header: some View {
        HStack {
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.marquee)
            Spacer()
            HStack(spacing: 20) {
                NavigationLink {
                    ReleaseCalendarView()
                } label: {
                    Image(systemName: "calendar")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Release calendar")
                NavigationLink {
                    NotificationsView()
                } label: {
                    Image(systemName: "bell")
                        .overlay(alignment: .topTrailing) {
                            if unreadCount > 0 {
                                Circle().fill(.red).frame(width: 7, height: 7).offset(x: 2, y: -2)
                            }
                        }
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Notifications")
                Menu {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button {
                        showMenuImport = true
                    } label: {
                        Label("Import Existing List", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        showInviteSheet = true
                    } label: {
                        Label("Invite a Friend", systemImage: "person.badge.plus")
                    }
                    Button(role: .destructive) {
                        showLogoutConfirm = true
                    } label: {
                        Label("Log Out", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Menu")
                .confirmationDialog("Log out of Cini?",
                                    isPresented: $showLogoutConfirm, titleVisibility: .visible) {
                    Button("Log out", role: .destructive) {
                        Task { await session.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                }
            }
            .font(.title3)
            .foregroundStyle(Theme.ink)
        }
        .padding(.top, 8)
    }

    /// Jump straight into the lists that answer "what should I watch?"
    private var quickPills: some View {
        HStack(spacing: 10) {
            PillButton(title: "Trending", systemImage: "chart.line.uptrend.xyaxis", style: .outlined) {
                // Trending lives in Search's browse modes — one home.
                tabRouter.pendingSearchBrowse = .trending
                tabRouter.selection = .search
            }
            PillButton(title: "Friend Recs", systemImage: "paperplane", style: .outlined) {
                tabRouter.pendingListsTab = .friendRecs
                tabRouter.selection = .lists
            }
            Spacer()
        }
    }

    /// Not a field — every search entry point opens the one Search screen.
    private var searchBar: some View {
        Button {
            tabRouter.selection = .search
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                Text("Search a movie, member, etc.")
                    .foregroundStyle(Theme.gray)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        }
        .buttonStyle(.plain)
    }

    // MARK: Feed

    private var yourFeed: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("YOUR FEED")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.top, 6)

            if let profile = session.profile, profile.streakAtRisk {
                streakBanner(profile.streakWeeks)
            }

            if events.isEmpty {
                if feedLoaded {
                    emptyState
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                }
            }

            ForEach(events) { event in
                FeedCard(
                    event: event,
                    initiallyLiked: likedEventIDs.contains(event.id),
                    onOpenMovie: { detailMovie = $0 },
                    onQuickAdd: { logMovie = $0 },
                    onOpenMember: { memberTarget = $0 }
                )
            }
        }
    }

    /// The streak is alive but unfed this week — one tap to keep it.
    private func streakBanner(_ weeks: Int) -> some View {
        HairlineCard {
            HStack(spacing: 14) {
                Image(systemName: "flame.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.gold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(weeks)-week streak ends Sunday")
                        .font(.subheadline.weight(.bold))
                    Text("Rank one movie this week to keep it alive.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
                PillButton(title: "Rank") { showRankSheet = true }
            }
        }
        .sheet(isPresented: $showRankSheet) {
            SearchView()
        }
    }

    /// First session: don't describe the app, point at the one action
    /// that starts everything. (The Ask Cini FAB is always present.)
    private var emptyState: some View {
        HairlineCard {
            VStack(spacing: 14) {
                Image(systemName: "film.stack").font(.title).foregroundStyle(Theme.gold)
                Text("Your feed starts with you")
                    .font(Theme.serif(24))
                Text("Rank one movie and Cini starts learning your taste. Friends' rankings land here as you follow them.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)

                PillButton(title: "Rank your first movie", systemImage: "plus.circle") {
                    tabRouter.selection = .search
                }
                PillButton(title: "Import your history", systemImage: "square.and.arrow.down",
                           style: .outlined) {
                    showImport = true
                }
                Button {
                    tabRouter.openMembersSearch = true
                    tabRouter.selection = .search
                } label: {
                    Text("Find friends to follow")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain)
                .padding(.top, 2)

                if #available(iOS 26.0, *) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                        Text("Or tap the sparkles — Ask Cini can pick, save, and rank for you.")
                    }
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $showImport) {
            LetterboxdImportView()
        }
    }

    /// A tapped push left its target on the router — open it.
    private func consumePush() {
        if let movieID = tabRouter.pendingPushMovieID {
            tabRouter.pendingPushMovieID = nil
            Task {
                if let movie = try? await TMDBService.shared.details(for: movieID) {
                    store.cache(movie)
                    detailMovie = movie
                }
            }
        }
        if let member = tabRouter.pendingPushMember {
            tabRouter.pendingPushMember = nil
            memberTarget = member
        }
    }

    private func loadFeed() async {
        // Cold start: show the last feed from disk instantly while the
        // fresh one loads — the app never opens to a blank screen.
        if events.isEmpty, let cached = FeedDiskCache.load() {
            events = cached
        }
        if let fresh = try? await SupabaseService.shared.feed() {
            events = fresh
            FeedDiskCache.save(fresh)
        }
        likedEventIDs = await SupabaseService.shared.myLikedEventIDs(events.map(\.id))
        unreadCount = await SupabaseService.shared.unreadNotificationCount()
        feedLoaded = true
    }
}

/// Last-known feed, persisted so launch shows content immediately.
enum FeedDiskCache {
    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("feed-cache.json")
    }

    static func load() -> [FeedEventRow]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([FeedEventRow].self, from: data)
    }

    static func save(_ events: [FeedEventRow]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(events) {
            try? data.write(to: url, options: .atomic)
        }
    }

    /// On sign-out — the next account must not see this user's feed.
    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}

// MARK: - Activity card

/// Lightweight navigation handle for a member profile.
struct MemberRef: Identifiable, Hashable {
    let id: UUID
    let username: String
}

struct FeedCard: View {
    let event: FeedEventRow
    var initiallyLiked = false
    var onOpenMovie: (Movie) -> Void = { _ in }
    var onQuickAdd: (Movie) -> Void = { _ in }
    var onOpenMember: (MemberRef) -> Void = { _ in }

    @Environment(RankingStore.self) private var store
    @State private var liked = false
    @State private var likeInFlight = false
    @State private var showComments = false

    private var movie: Movie? { event.movies?.asMovie }
    private var actorName: String { event.profiles?.username ?? "someone" }

    private var headline: Text {
        let title = Text(movie?.title ?? "a movie").bold()
        switch event.eventType {
        case "ranked":
            return Text("\(actorName) ranked ") + title
        case "watchlisted":
            return Text("\(actorName) wants to watch ") + title
        case "noted":
            return Text("\(actorName) wrote about ") + title
        case "streak_milestone":
            return Text("\(actorName) hit a streak milestone 🔥")
        case "challenge_milestone":
            return Text("\(actorName) hit a challenge milestone 🏆")
        default:
            return Text("\(actorName) shared an update")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    onOpenMember(MemberRef(id: event.userId, username: actorName))
                } label: {
                    AvatarView(url: event.profiles?.avatarUrl.flatMap(URL.init), size: 48,
                               name: preferredName(event.profiles?.displayName, event.profiles?.username))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    headline.font(.subheadline)
                    if let movie {
                        Text([movie.genres.first, movie.releaseYear.map(String.init)]
                            .compactMap(\.self).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                Spacer()
                // Score sits where every list row puts it.
                if event.eventType == "ranked", let score = event.payload?.score {
                    ScoreBadge(score: score, size: 44)
                }
            }

            HStack(spacing: 18) {
                Button {
                    guard !likeInFlight else { return }
                    likeInFlight = true
                    Haptics.tap()
                    liked.toggle()   // optimistic; reverted if the call fails
                    Task {
                        defer { likeInFlight = false }
                        do { try await SupabaseService.shared.toggleLike(eventID: event.id) }
                        catch {
                            liked.toggle()
                            ToastCenter.shared.saveFailed()
                        }
                    }
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? .red : Theme.ink)
                }
                Button { showComments = true } label: {
                    Image(systemName: "bubble.right")
                }
                if let movie {
                    ShareLink(item: "\(movie.title) — on Cini 🎬") {
                        Image(systemName: "paperplane")
                            .foregroundStyle(Theme.ink)
                    }
                }
            }
            .font(.body)
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)

            Text(event.createdAt.formatted(.relative(presentation: .named)))
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .padding(14)
        // The artwork lives IN the card: blended along the right edge
        // under a fade so the text stays clean.
        .background(
            ZStack(alignment: .trailing) {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                if let movie {
                    // Overlay-isolated like the movie hero: the bitmap's
                    // size can never leak into the card's layout.
                    Color.clear
                        .frame(width: 150)
                        .frame(maxHeight: .infinity)
                        .overlay {
                            CachedAsyncImage(url: movie.backdropURL ?? movie.posterURL) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.clear
                            }
                        }
                        .clipped()
                        .mask(
                        LinearGradient(colors: [.clear, .black],
                                       startPoint: .leading, endPoint: .trailing)
                    )
                    .opacity(0.32)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        )
        // Same corner as the movie page: (+) / bookmark on the artwork.
        .overlay(alignment: .bottomTrailing) {
            if let movie {
                ArtworkQuickActions(movie: movie, onLog: onQuickAdd)
                    .padding(12)
            }
        }
        // The whole card opens the referenced title; the action buttons
        // inside still win their own taps.
        .contentShape(Rectangle())
        .onTapGesture {
            if let movie { onOpenMovie(movie) }
        }
        // Liked state arrives after the card renders (one query for the
        // whole feed) — adopt it whenever it changes.
        .onChange(of: initiallyLiked, initial: true) { _, isLiked in
            liked = isLiked
        }
        .sheet(isPresented: $showComments) {
            CommentsSheet(eventID: event.id)
                .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Comments

struct CommentsSheet: View {
    /// Comments hang off a feed event — the feed passes its card's event,
    /// the movie page passes the 'ranked' event behind a public rating.
    let eventID: UUID

    @State private var comments: [CommentRow] = []
    @State private var draft = ""
    @State private var loaded = false
    @State private var blockCandidate: CommentRow?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !loaded {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if comments.isEmpty {
                    Spacer()
                    Text("No comments yet — say something nice.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                    Spacer()
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            NavigationLink {
                                MemberProfileView(userID: comment.userId,
                                                  username: comment.profiles?.username ?? "member")
                            } label: {
                                AvatarView(url: comment.profiles?.avatarUrl.flatMap(URL.init), size: 36,
                                           name: preferredName(comment.profiles?.displayName, comment.profiles?.username))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("@\(comment.profiles?.username ?? "member")")
                                        .font(.caption.weight(.bold))
                                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.gray)
                                }
                                Text(comment.body).font(.subheadline)
                            }
                        }
                        .listRowBackground(Theme.background)
                        // Long-press: delete your own, moderate others'.
                        .contextMenu {
                            if comment.userId == SupabaseService.shared.currentUserID {
                                Button(role: .destructive) {
                                    Task {
                                        do {
                                            try await SupabaseService.shared.deleteComment(id: comment.id)
                                            ToastCenter.shared.show("Comment deleted")
                                            await reload()
                                        } catch {
                                            ToastCenter.shared.saveFailed()
                                        }
                                    }
                                } label: {
                                    Label("Delete my comment", systemImage: "trash")
                                }
                            }
                            Button(role: .destructive) {
                                Task {
                                    await SupabaseService.shared.report(
                                        kind: "comment", subjectID: comment.id.uuidString)
                                    ToastCenter.shared.show("Reported — we'll review it")
                                }
                            } label: {
                                Label("Report comment", systemImage: "flag")
                            }
                            Button(role: .destructive) {
                                blockCandidate = comment
                            } label: {
                                Label("Block @\(comment.profiles?.username ?? "member")",
                                      systemImage: "hand.raised")
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollDismissesKeyboard(.interactively)
                }

                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
                    Button {
                        Task { await post() }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.title)
                            .foregroundStyle(
                                draft.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Theme.gray.opacity(0.4) : Theme.marquee)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(12)
                .background(.thinMaterial)
            }
            .background(Theme.background)
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Blocking is heavy — always confirm before mutual invisibility.
        .confirmationDialog(
            "Block @\(blockCandidate?.profiles?.username ?? "member")?",
            isPresented: Binding(get: { blockCandidate != nil },
                                 set: { if !$0 { blockCandidate = nil } }),
            titleVisibility: .visible,
            presenting: blockCandidate
        ) { comment in
            Button("Block @\(comment.profiles?.username ?? "member")", role: .destructive) {
                Task {
                    do {
                        try await SupabaseService.shared.block(comment.userId)
                        ToastCenter.shared.show("Blocked — their content is hidden everywhere")
                        await reload()
                    } catch {
                        ToastCenter.shared.saveFailed()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You won't see each other's rankings, notes, or activity.")
        }
        .task { await reload() }
    }

    private func reload() async {
        comments = (try? await SupabaseService.shared.comments(eventID: eventID)) ?? []
        loaded = true
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        draft = ""
        do {
            try await SupabaseService.shared.comment(eventID: eventID, body: body)
        } catch {
            draft = body   // give the text back instead of eating it
            ToastCenter.shared.saveFailed()
        }
        await reload()
    }
}

// MARK: - Stubs reached from the header

struct ReleaseCalendarView: View {
    @State private var upcoming: [Movie] = []
    @State private var ticketsMovie: Movie?
    @State private var detailMovie: Movie?

    private func releaseDate(_ movie: Movie) -> Date? {
        movie.releaseDateFull.flatMap { DateFormatter.posixDay.date(from: $0) }
    }

    var body: some View {
        List(upcoming) { movie in
            HStack(spacing: 12) {
                PosterView(url: movie.posterURL, width: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(movie.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if let date = releaseDate(movie) {
                        Text(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    if !movie.genres.isEmpty {
                        Text(movie.genres.prefix(2).joined(separator: ", "))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                Spacer()
                PillButton(title: "Tickets", systemImage: "ticket", style: .outlined) {
                    ticketsMovie = movie
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { detailMovie = movie }
            .listRowBackground(Theme.background)
        }
        .listStyle(.plain)
        .background(Theme.background)
        .navigationTitle("Release Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $ticketsMovie) { movie in
            // Pre-aimed at release day so presale showtimes appear.
            ShowtimesSheet(movie: movie, initialDate: releaseDate(movie))
        }
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .task {
            let movies = (try? await TMDBService.shared.upcoming()) ?? []
            // Soonest first; undated entries sink.
            upcoming = movies.sorted {
                (releaseDate($0) ?? .distantFuture) < (releaseDate($1) ?? .distantFuture)
            }
        }
    }
}

struct NotificationsView: View {
    @State private var rows: [NotificationRow] = []
    @State private var loaded = false
    @State private var detailMovie: Movie?
    @State private var memberTarget: MemberRef?
    @State private var showImport = false
    @State private var showRankSheet = false

    var body: some View {
        List {
            if rows.isEmpty && loaded {
                VStack(spacing: 8) {
                    Image(systemName: "bell").font(.title).foregroundStyle(Theme.gray)
                    Text("Nothing yet").font(.subheadline.weight(.semibold))
                    Text("Likes, comments, new followers, and friends ranking your watchlist movies land here.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 32)
                .listRowBackground(Theme.background)
            }
            ForEach(rows) { row in
                HStack(spacing: 12) {
                    Button {
                        if let actorId = row.actorId, let actor = row.actor {
                            memberTarget = MemberRef(id: actorId, username: actor.username)
                        }
                    } label: {
                        AvatarView(url: row.actor?.avatarUrl.flatMap(URL.init), size: 42,
                           name: preferredName(row.actor?.displayName, row.actor?.username))
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(headline(row)).font(.subheadline)
                        Text(row.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                    if let path = row.movies?.posterPath {
                        PosterView(url: TMDBService.imageURL(path: path, size: .poster), width: 32)
                    }
                    if row.readAt == nil {
                        Circle().fill(Theme.marquee).frame(width: 8, height: 8)
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if let movieId = row.movieId, let stub = row.movies {
                        detailMovie = Movie(tmdbID: movieId, mediaKind: "movie", title: stub.title,
                                            releaseYear: nil, posterPath: stub.posterPath,
                                            backdropPath: nil, genres: [], certification: nil,
                                            runtimeMinutes: nil, director: nil, overview: nil)
                    } else if let actorId = row.actorId, let actor = row.actor {
                        memberTarget = MemberRef(id: actorId, username: actor.username)
                    }
                }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .background(Theme.background)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .navigationDestination(item: $memberTarget) { member in
            MemberProfileView(userID: member.id, username: member.username)
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    NotificationPreferencesView()
                } label: {
                    Image(systemName: "gearshape")
                }
            }
        }
        .task {
            rows = (try? await SupabaseService.shared.notifications()) ?? []
            loaded = true
            await SupabaseService.shared.markNotificationsRead()
            try? await UNUserNotificationCenter.current().setBadgeCount(0)
        }
    }

    private func headline(_ row: NotificationRow) -> AttributedString {
        let who = "@\(row.actor?.username ?? "someone")"
        let movie = row.movies?.title ?? "a movie"
        let text: String
        switch row.kind {
        case "new_follower": text = "**\(who)** started following you"
        case "like": text = "**\(who)** liked your activity on **\(movie)**"
        case "comment": text = "**\(who)** commented on **\(movie)**"
        case "friend_ranked_watchlist_movie": text = "**\(who)** ranked **\(movie)** — it's on your Want to Watch list"
        case "watchlist_showing": text = "**\(movie)** from your watchlist is playing near you 🎬"
        case "invite_joined": text = "**\(who)** joined Cini from your invite — you now follow each other 🎉"
        case "direct_rec": text = "**\(who)** recommended **\(movie)** to you 🎬"
        default: text = "**\(who)** did something new"
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
