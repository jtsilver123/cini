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
    @State private var showMenuImport = false
    @State private var showSettings = false
    @State private var showInviteSheet = false
    @State private var showLogoutConfirm = false
    @State private var showAskRecs = false
    @State private var showRespondRecs = false
    @State private var pendingAsks: [RecRequestRow] = []
    @State private var promoted: Movie?
    @State private var promotedReason: String?
    @State private var tonightCards: [TonightCardItem] = []
    // Picks dismissed today, persisted so a swiped/✕'d pick stays gone.
    @AppStorage("tonight.dismissed.date") private var tonightDismissedDate = ""
    @AppStorage("tonight.dismissed.ids") private var tonightDismissedIDs = ""
    @State private var watchPlanContext: WatchPlanContext?
    @State private var friendsWatchingRows: [FriendWatchingRow] = []
    @State private var watchingStory: FriendWatchingRow?
    @AppStorage("feed.hideWatchingStories") private var hideWatchingStories = false

    var body: some View {
        NavigationStack {
            // Header, search, and the pill row stay frozen; only the
            // feed itself scrolls underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 18) {
                    header
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollViewReader { proxy in
                    ScrollView {
                        yourFeed
                            .padding(.horizontal, 16)
                            .id("feedTop")
                    }
                    .refreshable { await loadFeed(); await loadTonightStack(force: true) }
                    // Tapping the Feed tab while on Feed jumps back to the top.
                    .onChange(of: tabRouter.retap[.feed]) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("feedTop", anchor: .top) }
                    }
                }
            }
            .background(Theme.background)
            .task { await loadFeed() }
            .task { friendsWatchingRows = await SupabaseService.shared.friendsWatching() }
            .task(id: store.isLoaded) { await loadTonightStack() }
            // Tapped push notifications land here (cold launch included) —
            // consume on appear AND on change, since the tab stays alive.
            .onAppear { consumePush() }
            .onChange(of: tabRouter.pendingPushMovieID) { _, _ in consumePush() }
            .onChange(of: tabRouter.pendingPushMember) { _, _ in consumePush() }
            .onChange(of: tabRouter.pendingWatchPlan) { _, _ in consumePush() }
            .sheet(item: $watchPlanContext) { ctx in
                PlanWatchSheet(context: ctx)
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $watchingStory) { row in
                WatchingStorySheet(
                    row: row,
                    onOpenShow: { openShow($0) },
                    onPlanTogether: { r in
                        // Let the story sheet finish dismissing before presenting
                        // the plan sheet — two sheets in one runloop can swallow
                        // the second on device.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            watchPlanContext = WatchPlanContext(
                                movieID: r.showId,
                                friend: MemberRef(id: r.userId, username: r.username))
                        }
                    }
                )
            }
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
                    .presentationDetents([.large])
            }
            .sheet(isPresented: $showAskRecs) {
                RequestRecsSheet()
            }
            .sheet(isPresented: $showRespondRecs, onDismiss: {
                Task { pendingAsks = (try? await SupabaseService.shared.incomingRecRequests()) ?? [] }
            }) {
                RespondRecSheet()
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
            HStack(spacing: 4) {
                Button {
                    tabRouter.selection = .search
                } label: {
                    Image(systemName: "magnifyingglass")
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Search")
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
                .alert("Log out of Cini?", isPresented: $showLogoutConfirm) {
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

    /// "What should I watch?" aimed at your actual friends: pick people,
    /// optionally narrow by type/genre, and their answers land in
    /// Friend Recs.
    private var askForRecsRow: some View {
        Button {
            showAskRecs = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "hand.wave")
                    .foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Ask friends for a rec")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("Pick friends, set the mood, get picks back")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.gray)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        }
        .buttonStyle(.plain)
    }

    /// Bookmarks shouldn't be where titles go to die: after two weeks,
    /// the oldest unwatched save gets one gentle nudge. ✕ snoozes that
    /// title forever; only one nudge shows at a time.
    @AppStorage("feed.nudgeDismissed") private var nudgeDismissedRaw = ""

    private var nudgeCandidate: Movie? {
        guard store.isLoaded else { return nil }
        let dismissed = Set(nudgeDismissedRaw.split(separator: ",").map(String.init))
        let cutoff = Date().addingTimeInterval(-14 * 86400)
        for item in store.watchlist.reversed() where item.createdAt < cutoff {
            if dismissed.contains(String(item.movieID)) { continue }
            if let movie = store.movie(item.movieID) { return movie }
        }
        return nil
    }

    private func followThroughBanner(_ movie: Movie) -> some View {
        HStack(spacing: 10) {
            PosterView(url: movie.posterURL, width: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text("Still meaning to watch \(movie.title)?")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(2)
                Text("It's been on your list a while — tonight's the night?")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            Spacer()
            Button {
                nudgeDismissedRaw += nudgeDismissedRaw.isEmpty
                    ? String(movie.tmdbID) : ",\(movie.tmdbID)"
            } label: {
                Image(systemName: "xmark")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        .contentShape(Rectangle())
        .onTapGesture {
            store.cache(movie)
            detailMovie = movie
        }
    }

    /// Someone's waiting on your taste — surface it without a push.
    private var pendingAsksBanner: some View {
        Button {
            showRespondRecs = true
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "envelope.badge")
                    .foregroundStyle(Theme.marquee)
                Text(pendingAsksHeadline)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .multilineTextAlignment(.leading)
                Spacer()
                Text("Send one")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.marquee)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.marqueeSoft))
        }
        .buttonStyle(.plain)
    }

    private var pendingAsksHeadline: String {
        guard let first = pendingAsks.first else { return "" }
        let who = "@\(first.profiles?.username ?? "A friend")"
        if pendingAsks.count == 1 {
            return "\(who) wants \(first.criteriaText) from you"
        }
        return "\(who) + \(pendingAsks.count - 1) more want recs from you"
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
            // What friends are binging right now — story circles at the top.
            if !hideWatchingStories {
                FriendsWatchingShelf(rows: friendsWatchingRows, onTap: { watchingStory = $0 })
                    .padding(.top, 6)
                    // Break out of the feed's 16pt inset so the stories scroll
                    // edge-to-edge (Instagram-style) instead of clipping at the margin.
                    .padding(.horizontal, -16)
            }

            // Anything that needs you first — one banner at a time, never a stack.
            if !pendingAsks.isEmpty {
                pendingAsksBanner
            } else if let profile = session.profile, profile.streakAtRisk {
                streakBanner(profile.streakWeeks)
            } else if let nudge = nudgeCandidate {
                followThroughBanner(nudge)
            }

            // The daily hook — up to three streamable "watch tonight" picks,
            // stacked like a deck you can swipe through.
            if !tonightCards.isEmpty {
                TonightStack(
                    items: tonightCards,
                    onOpen: { detailMovie = $0 },
                    onRank: { logMovie = $0 },
                    onSave: { saveTonight($0) },
                    onDismiss: { dismissTonight($0) }
                )
                .padding(.top, 2)
            }

            askForRecsRow

            // Beli-style unlock progress — until everything's unlocked.
            if unlockCatalog.contains(where: { !session.isUnlocked($0.id) }) {
                FeedUnlockCard()
                    .padding(.top, 6)
            }

            if events.isEmpty {
                if feedLoaded {
                    emptyState
                } else {
                    FeedSkeleton()
                        .padding(.top, 4)
                }
            }

            // Friends' activity. (Tonight's Pick at the top is now the single
            // first-party recommendation surface — the old interspersed
            // "Promoted release" card was redundant and removed.)
            ForEach(Array(events.enumerated()), id: \.element.id) { _, event in
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

    /// Where the featured release flows into the feed: after the 4th post so
    /// friends' activity leads, or after the last post in a shorter feed.
    private var promotedSlot: Int { min(3, events.count - 1) }

    @ViewBuilder private var promotedCard: some View {
        if let promoted {
            PromotedReleaseCard(
                movie: promoted,
                reason: promotedReason,
                onOpen: { detailMovie = $0 },
                onQuickAdd: { logMovie = $0 }
            )
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
                // Consistent with every other "rank" entry point — go to the
                // Search tab rather than a one-off sheet.
                PillButton(title: "Rank") { tabRouter.selection = .search }
            }
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
                Text("Rank one movie and Cini learns what you like. Follow friends to see their rankings here too.")
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

                if #available(iOS 26.0, *), ChatEligibility.canEverBeAvailable {
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
    /// Open a show from the "Friends are watching" shelf (TV ids are negative).
    private func openShow(_ showID: Int) {
        Task {
            if let movie = try? await TMDBService.shared.details(for: showID) {
                store.cache(movie)
                detailMovie = movie
            }
        }
    }

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
        if let plan = tabRouter.pendingWatchPlan {
            tabRouter.pendingWatchPlan = nil
            watchPlanContext = plan
        }
    }

    /// The genre the user ranks most (favorites weigh more) — drives the
    /// promoted release pick. Nil until they've ranked something.
    private func topGenre() -> String? {
        guard store.isLoaded else { return nil }
        var counts: [String: Double] = [:]
        for item in store.watchedItems {
            guard let movie = store.movie(item.id) else { continue }
            let weight = max(0.5, item.score / 5)   // higher-scored picks count more
            for genre in movie.genres { counts[genre, default: 0] += weight }
        }
        return counts.max { $0.value < $1.value }?.key
    }

    /// Pick one upcoming/new release to feature, biased to the user's taste
    /// and excluding anything they've already ranked or saved.
    private func loadPromoted() async {
        guard promoted == nil,
              let upcoming = try? await TMDBService.shared.upcoming(), !upcoming.isEmpty
        else { return }
        let seen = Set(store.watchedItems.map(\.id)).union(store.watchlist.map(\.movieID))
        let fresh = upcoming.filter { !seen.contains($0.tmdbID) && $0.posterPath != nil }
        guard !fresh.isEmpty else { return }
        if let genre = topGenre(), let match = fresh.first(where: { $0.genres.contains(genre) }) {
            promotedReason = "Because you like \(genre.lowercased())"
            promoted = match
        } else {
            promotedReason = "New this season"
            promoted = fresh.first
        }
        if let promoted { store.cache(promoted) }
    }

    /// Load several Tonight's Pick candidates and keep up to three that are
    /// actually streamable (with the service to show on the card). Skips picks
    /// already dismissed today.
    private func loadTonightStack(force: Bool = false) async {
        // Lazy on the .task path; a manual pull-to-refresh forces a rebuild so
        // dismissing all picks isn't permanent until an app relaunch.
        guard force || tonightCards.isEmpty,
              let picks = try? await SupabaseService.shared.tonightPicks(limit: 10), !picks.isEmpty
        else { return }
        let skip = dismissedTonightToday()
        let rows = (try? await SupabaseService.shared.movies(ids: picks.map(\.movieId))) ?? []
        var byID: [Int: Movie] = [:]
        for row in rows { byID[row.tmdbId] = row.asMovie }
        var cards: [TonightCardItem] = []
        for pick in picks {
            if cards.count >= 3 { break }
            if skip.contains(pick.movieId) { continue }
            guard let movie = byID[pick.movieId] ?? store.movie(pick.movieId),
                  movie.posterPath != nil else { continue }
            // Must be streamable — keep only picks on a streaming service, and
            // grab that service's logo for the badge.
            guard let providers = try? await TMDBService.shared.watchProviders(for: pick.movieId),
                  let provider = providers.flatrate?.first else { continue }
            store.cache(movie)
            cards.append(TonightCardItem(movie: movie,
                                         reason: Self.tonightReason(for: pick),
                                         service: provider.providerName,
                                         serviceLogo: provider.logoURL))
        }
        tonightCards = cards
    }

    private func todayKey() -> String { DateFormatter.posixDay.string(from: Date()) }

    /// Picks the user dismissed today (reset automatically on a new day).
    private func dismissedTonightToday() -> Set<Int> {
        guard tonightDismissedDate == todayKey() else { return [] }
        return Set(tonightDismissedIDs.split(separator: ",").compactMap { Int($0) })
    }

    private func dismissTonight(_ id: Int, toast: Bool = true) {
        var set = dismissedTonightToday()
        set.insert(id)
        tonightDismissedDate = todayKey()
        tonightDismissedIDs = set.map(String.init).joined(separator: ",")
        withAnimation(.snappy) { tonightCards.removeAll { $0.id == id } }
        if toast { ToastCenter.shared.show("Dismissed that rec") }
    }

    /// Swipe right on a Tonight's Pick → save it to Want to Watch and clear it
    /// from the deck (remembered so it won't resurface as a pick today).
    private func saveTonight(_ item: TonightCardItem) {
        if !store.isOnWatchlist(item.movie.tmdbID) {
            Task { await store.toggleWatchlist(movie: item.movie) }
        }
        Haptics.success()
        ToastCenter.shared.show("Saved to Want to Watch")
        dismissTonight(item.id, toast: false)
    }

    /// A reason that never overstates confidence. Lead with friends when they
    /// vouch for it; otherwise quote a predicted score only when it's genuinely
    /// high (a default ~6.5 for an uncached pick isn't a real prediction).
    static func tonightReason(for pick: TonightPickRow) -> String {
        var parts: [String] = []
        if pick.friendCount == 1, let friend = pick.topFriend {
            parts.append("@\(friend) loved it")
        } else if pick.friendCount > 1 {
            parts.append("\(pick.friendCount) friends loved it")
        }
        if pick.predicted >= 7.0 {
            parts.append("We think you'll rate it \(pick.predicted.formatted(.number.precision(.fractionLength(1))))")
        } else if parts.isEmpty {
            // Nothing strong to say — it's a title they already want to see.
            parts.append(pick.source == "watchlist" ? "On your Want to Watch" : "Picked for your taste")
        }
        return parts.joined(separator: " · ")
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
        pendingAsks = (try? await SupabaseService.shared.incomingRecRequests()) ?? []
        friendsWatchingRows = await SupabaseService.shared.friendsWatching()
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

/// A title + a friend, opened in the Plan-a-Watch sheet (from a watch-match
/// push or the "friends who want this" row on the movie page).
struct WatchPlanContext: Identifiable, Equatable {
    let movieID: Int
    let friend: MemberRef
    var id: String { "\(movieID)-\(friend.id.uuidString)" }
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
    @State private var heartPop = false
    // Stashed when a commenter is tapped; opened after the sheet dismisses so
    // the profile pushes cleanly in the main nav stack (not inside the sheet).
    @State private var pendingMember: MemberRef?

    private var movie: Movie? { event.movies?.asMovie }
    private var actorName: String { event.profiles?.username ?? "someone" }

    /// Toggle the like with optimistic UI + revert on failure (shared by the
    /// heart button and the double-tap gesture).
    private func toggleLike() {
        guard !likeInFlight else { return }
        likeInFlight = true
        Haptics.tap()
        liked.toggle()
        Task {
            defer { likeInFlight = false }
            do { try await SupabaseService.shared.toggleLike(eventID: event.id) }
            catch {
                liked.toggle()
                ToastCenter.shared.saveFailed()
            }
        }
    }

    /// Double-tap the card to like (Instagram-style) — only ever likes, never
    /// unlikes, and pops a heart.
    private func doubleTapLike() {
        if !liked { toggleLike() }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.5)) { heartPop = true }
        Task {
            try? await Task.sleep(for: .milliseconds(650))
            withAnimation(.easeOut(duration: 0.25)) { heartPop = false }
        }
    }

    private var headline: Text {
        let title = Text(movie?.title ?? "a movie").bold()
        switch event.eventType {
        case "ranked":
            return Text("\(actorName) ranked ") + title
        case "watchlisted":
            return Text("\(actorName) wants to watch ") + title
        case "noted":
            return Text("\(actorName) wrote about ") + title
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
                    headline.font(.subheadline).lineLimit(3)
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
                    toggleLike()
                } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? .red : Theme.ink)
                }
                Button { showComments = true } label: {
                    Image(systemName: "bubble.right")
                }
                if let movie {
                    ShareLink(item: "\(movie.title) — on Cini 🎬\n\(AppLinks.appStore)") {
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
        // Double-tap to like, Instagram-style — a heart pops in the center.
        .overlay {
            Image(systemName: "heart.fill")
                .font(.system(size: 64))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 8)
                .scaleEffect(heartPop ? 1 : 0.5)
                .opacity(heartPop ? 0.95 : 0)
                .allowsHitTesting(false)
        }
        // The whole card opens the referenced title; the action buttons
        // inside still win their own taps. Double-tap likes before single-tap
        // opens, so SwiftUI disambiguates correctly.
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { doubleTapLike() }
        .onTapGesture {
            if let movie { onOpenMovie(movie) }
        }
        // Liked state arrives after the card renders (one query for the
        // whole feed) — adopt it whenever it changes.
        .onChange(of: initiallyLiked, initial: true) { _, isLiked in
            liked = isLiked
        }
        .sheet(isPresented: $showComments, onDismiss: {
            if let m = pendingMember { pendingMember = nil; onOpenMember(m) }
        }) {
            CommentsSheet(eventID: event.id, onOpenMember: { member in
                pendingMember = member
                showComments = false
            })
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Comments

struct CommentsSheet: View {
    /// Comments hang off a feed event — the feed passes its card's event,
    /// the movie page passes the 'ranked' event behind a public rating.
    let eventID: UUID
    /// Tapping a commenter routes to their profile in the PRESENTER's nav stack
    /// (after this sheet dismisses) — never a cramped profile pushed inside the
    /// comments sheet.
    var onOpenMember: (MemberRef) -> Void = { _ in }

    @State private var comments: [CommentRow] = []
    @State private var draft = ""
    @State private var loaded = false
    @State private var blockCandidate: CommentRow?

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    ScrollView {
                        ListSkeleton(rows: 6)
                            .padding(.horizontal, 16)
                            .padding(.top, 12)
                    }
                } else if comments.isEmpty {
                    Spacer()
                    EmptyStateView(
                        icon: "bubble.left.and.bubble.right",
                        title: "Be the first",
                        message: "No comments yet — say something nice.")
                    Spacer()
                } else {
                    List(comments) { comment in
                        HStack(alignment: .top, spacing: 12) {
                            // A plain Button (not a List NavigationLink, which
                            // injects a disclosure chevron and breaks the row
                            // layout) — hand the member to the presenter so the
                            // real profile opens in the main nav stack.
                            Button {
                                onOpenMember(MemberRef(id: comment.userId,
                                                       username: comment.profiles?.username ?? "member"))
                            } label: {
                                AvatarView(url: comment.profiles?.avatarUrl.flatMap(URL.init), size: 36,
                                           name: preferredName(comment.profiles?.displayName, comment.profiles?.username))
                            }
                            .buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text("@\(comment.profiles?.username ?? "member")")
                                        .font(.caption.weight(.bold))
                                        .lineLimit(1)
                                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.gray)
                                        .lineLimit(1)
                                        .layoutPriority(-1)
                                }
                                Text(comment.body).font(.subheadline)
                            }
                            Spacer(minLength: 0)
                        }
                        .listRowBackground(Theme.background)
                        // Long-press: delete your own, moderate others'.
                        .contextMenu {
                            if comment.userId == SupabaseService.shared.currentUserID {
                                Button(role: .destructive) {
                                    Task {
                                        do {
                                            try await SupabaseService.shared.deleteComment(id: comment.id)
                                            // Offer Undo (re-post) — matches the
                                            // app's other destructive removals.
                                            let body = comment.body
                                            let eid = eventID
                                            ToastCenter.shared.showUndo("Comment deleted") {
                                                Task {
                                                    try? await SupabaseService.shared.comment(eventID: eid, body: body)
                                                    await reload()
                                                }
                                            }
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

            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            // safeAreaInset keeps the composer pinned ABOVE the keyboard.
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    TextField("Add a comment…", text: $draft, axis: .vertical)
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.fill))
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
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
        }
        // Blocking is heavy — always confirm before mutual invisibility.
        .alert(
            "Block @\(blockCandidate?.profiles?.username ?? "member")?",
            isPresented: Binding(get: { blockCandidate != nil },
                                 set: { if !$0 { blockCandidate = nil } }),
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
    @Environment(RankingStore.self) private var store
    @State private var upcoming: [Movie] = []
    @State private var detailMovie: Movie?
    // One sheet slot so tickets-vs-save can't race two presentations at once.
    private enum ActiveSheet: Identifiable {
        case tickets(Movie), save(Movie)
        var id: String {
            switch self {
            case .tickets(let m): return "t\(m.tmdbID)"
            case .save(let m): return "s\(m.tmdbID)"
            }
        }
    }
    @State private var activeSheet: ActiveSheet?

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
                // Tickets up top, save bottom-right — same corner the
                // bookmark lives in on every other card.
                VStack(alignment: .trailing, spacing: 10) {
                    PillButton(title: "Tickets", systemImage: "ticket", style: .outlined) {
                        activeSheet = .tickets(movie)
                    }
                    Button {
                        bookmarkTapped(movie: movie, store: store) { activeSheet = .save(movie) }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .font(.title3)
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(store.isOnWatchlist(movie.tmdbID)
                        ? "Remove from Want to Watch" : "Save to Want to Watch")
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .tickets(let movie):
                // Pre-aimed at release day so presale showtimes appear.
                ShowtimesSheet(movie: movie, initialDate: releaseDate(movie))
            case .save(let movie):
                SaveToListSheet(movie: movie)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
            }
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
    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [NotificationRow] = []
    @State private var loaded = false
    @State private var detailMovie: Movie?
    @State private var memberTarget: MemberRef?
    @State private var showImport = false
    @State private var showRankSheet = false
    @State private var showRespondRecs = false
    @State private var resolvedFollowReqs: [UUID: Bool] = [:]   // actorId → accepted

    private func respondFollow(_ requester: UUID, accept: Bool) {
        Haptics.tap()
        resolvedFollowReqs[requester] = accept
        Task {
            do {
                try await SupabaseService.shared.respondFollowRequest(requester: requester, accept: accept)
            } catch {
                // Don't leave the row showing "Accepted" if nothing happened.
                resolvedFollowReqs[requester] = nil
                ToastCenter.shared.saveFailed()
            }
        }
    }

    var body: some View {
        List {
            if !loaded {
                SearchSkeleton(kind: .members, rows: 6)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            }
            if rows.isEmpty && loaded {
                VStack(spacing: 10) {
                    Image(systemName: "bell").font(.title).foregroundStyle(Theme.gray)
                    Text("Nothing yet").font(.subheadline.weight(.semibold))
                    Text("Likes, comments, and friends' activity show up here. Add a few friends to get things moving.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                    PillButton(title: "Find friends", systemImage: "person.badge.plus") {
                        tabRouter.openMembersSearch = true
                        tabRouter.selection = .search
                        dismiss()
                    }
                    .padding(.top, 2)
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
                        Text(headline(row)).font(.subheadline).lineLimit(3)
                        Text(row.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                    if row.kind == "follow_request", let actorId = row.actorId {
                        if let accepted = resolvedFollowReqs[actorId] {
                            Text(accepted ? "Accepted" : "Declined")
                                .font(.caption.weight(.semibold)).foregroundStyle(Theme.gray)
                        } else {
                            HStack(spacing: 8) {
                                Button("Accept") { respondFollow(actorId, accept: true) }
                                    .font(.caption.weight(.bold)).foregroundStyle(.white)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(Theme.velvet))
                                Button("Decline") { respondFollow(actorId, accept: false) }
                                    .font(.caption.weight(.bold)).foregroundStyle(Theme.gray)
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        if let path = row.movies?.posterPath {
                            PosterView(url: TMDBService.imageURL(path: path, size: .poster), width: 32)
                        }
                        if row.readAt == nil {
                            Circle().fill(Theme.marquee).frame(width: 8, height: 8)
                        }
                    }
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    if row.kind == "rec_request" {
                        showRespondRecs = true
                    } else if let movieId = row.movieId, let stub = row.movies {
                        detailMovie = Movie(tmdbID: movieId,
                                            mediaKind: movieId < 0 ? "tv" : "movie",
                                            title: stub.title,
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
        .sheet(isPresented: $showRespondRecs) {
            RespondRecSheet()
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
                .accessibilityLabel("Notification settings")
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
        // Prefer the joiner's real profile name for "a contact joined" — it
        // reads like a person you know, not a handle. (We don't store the name
        // you saved them under, only a hash of their number.)
        let name = (row.actor?.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? who
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
        case "rec_request": text = "**\(who)** wants a rec from you — send one 🎬"
        case "follow_request": text = "**\(who)** asked to follow you"
        case "follow_request_approved": text = "**\(who)** accepted your follow request"
        case "contact_joined": text = "**\(name)** from your contacts just joined Cini 🎬"
        case "saved_your_rank": text = "**\(who)** saved **\(movie)** — you ranked it 🔖"
        case "streak_reminder": text = "Your streak ends Sunday — rank one title to keep it alive 🔥"
        case "tonight_pick": text = "Tonight's pick: **\(movie)** 🍿"
        case "watch_match": text = "**\(who)** also wants to watch **\(movie)** — plan a movie night? 🍿"
        case "watch_invite": text = "**\(who)** wants to watch **\(movie)** together — when works? 🎬"
        case "streaming_now": text = "**\(movie)** is streaming now — it's on your Want to Watch 🍿"
        case "season_premiere": text = "New season of **\(movie)** premieres this week 🎬"
        case "rate_nudge": text = "Seen **\(movie)** yet? Tap to rank it 🎬"
        case "friend_loved": text = "**\(who)** just ranked **\(movie)** — one of your favorites 🍿"
        default: text = "**\(who)** did something new"
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }
}
