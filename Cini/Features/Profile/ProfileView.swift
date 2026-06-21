import SwiftUI
import RankingEngine

/// Last-known follower/following counts per user, so a profile shows real
/// numbers instantly on return instead of flashing 0 while the live count loads.
enum ProfileCountsCache {
    static func get(_ id: UUID) -> (followers: Int, following: Int)? {
        let d = UserDefaults.standard
        let fk = "pc.f.\(id.uuidString)"
        guard d.object(forKey: fk) != nil else { return nil }
        return (d.integer(forKey: fk), d.integer(forKey: "pc.g.\(id.uuidString)"))
    }
    static func set(_ id: UUID, followers: Int, following: Int) {
        let d = UserDefaults.standard
        d.set(followers, forKey: "pc.f.\(id.uuidString)")
        d.set(following, forKey: "pc.g.\(id.uuidString)")
    }
}

/// One profile UI for everyone: your own tab and any member you tap into.
/// Identity → stats → (Edit/Share | Follow) → Taste Profile → Activity →
/// ranked list. Self gets the menu (import, sign out); others get Follow.
struct ProfileScreen: View {
    /// nil = the signed-in user.
    let userID: UUID?
    var username: String?

    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.horizontalSizeClass) private var hSize

    @State private var profile: Profile?
    @State private var rankings: [RankingRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var events: [FeedEventRow] = []
    // Diary watches (incl. Letterboxd imports) merged into Activity — one
    // history surface instead of a separate Diary screen.
    @State private var watches: [WatchRow] = []
    @State private var watchMovies: [Int: Movie] = [:]
    @State private var showAllActivity = false
    @State private var followerCount = 0
    @State private var followingCount = 0
    /// True once we have a real value (cached or freshly loaded) — until then
    /// the stat shows "—" rather than a misleading 0.
    @State private var hasCounts = false
    @State private var following = false
    @State private var requested = false   // pending follow request to a private account
    @State private var followBusy = false  // a follow/unfollow tap is in flight
    @State private var blocked = false
    @State private var reported = false
    @State private var showBlockConfirm = false
    @State private var showAskRec = false
    @State private var matchPct: Double?
    @State private var globalRank: Int?
    /// Tapping the profile photo opens a full-screen view of it.
    @State private var zoomAvatar = false
    @State private var watchlistCount = 0
    /// Member's watchlist rows also on the viewer's list (member profiles only).
    @State private var bothWantToWatch: [WatchlistRow] = []
    @State private var profileTab = 0   // 0 = Activity, 1 = Taste Profile
    @State private var showImport = false
    @State private var showEditProfile = false
    @State private var showSettings = false
    @State private var showLeaderboard = false
    @State private var showInviteSheet = false
    @State private var showSuggested = false
    @State private var suggested: [SuggestedMember] = []
    @State private var followedSuggested: Set<UUID> = []
    @State private var requestedSuggested: Set<UUID> = []
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var commentsLink: CommentsLink?
    @State private var commentMemberTarget: MemberRef?
    @State private var likedEventIDs: Set<UUID> = []
    /// Live comment counts reported back from open threads, keyed by event id.
    @State private var commentCountOverrides: [UUID: Int] = [:]
    @State private var watchingRows: [WatchingRow] = []
    @State private var bothWatching: [WatchingRow] = []
    @State private var loaded = false
    @State private var lastLoaded: Date = .distantPast
    @State private var showLogoutConfirm = false
    @State private var showTop5Share = false
    @State private var showMatchShare = false

    private var isSelf: Bool { userID == nil || userID == session.profile?.id }
    private var resolvedID: UUID? { userID ?? session.profile?.id }

    var body: some View {
        // The self header (name, share, menu) stays frozen; content scrolls.
        VStack(spacing: 0) {
            if isSelf {
                header
                    .screenHPadding()
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Theme.background)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // A member profile opens with nothing cached — show the
                    // shape of the page, never zeros and blanks.
                    if !loaded && profile == nil {
                        ProfileSkeleton()
                            .padding(.vertical, 16)
                            .screenHPadding()
                    } else {
                        VStack(spacing: 18) {
                            identity
                            topThree
                            if isSelf, !rankings.isEmpty { shareTopFiveButton }
                            statRow
                            buttonRow
                            listRows
                            statCards
                            profileTabs
                        }
                        .padding(.vertical, 16)
                        .screenHPadding()
                        .id("profileTop")
                    }
                }
                .refreshable { await load() }
                // Re-tapping the Profile tab jumps back to the top.
                .onChange(of: tabRouter.retap[.profile]) { _, _ in
                    withAnimation(.snappy) { proxy.scrollTo("profileTop", anchor: .top) }
                }
            }
        }
        .nativeContentWidth()
        .background(Theme.background)
        .sheet(isPresented: $showAskRec) {
            RequestRecsSheet(recipientID: resolvedID,
                             recipientUsername: profile?.username ?? username)
        }
        .sheet(isPresented: $showImport) {
            LetterboxdImportView()
        }
        .sheet(isPresented: $showEditProfile) {
            if let profile {
                EditProfileView(profile: profile) {
                    Task {
                        await load()
                        await session.loadProfile()
                    }
                }
            }
        }
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .navigationDestination(item: $commentsLink) { link in
            CommentsSheet(
                eventID: link.id,
                context: link.context,
                onOpenMember: { commentMemberTarget = $0 },
                onCommentCountChange: { commentCountOverrides[link.id] = $0 }
            )
        }
        .navigationDestination(item: $commentMemberTarget) { member in
            MemberProfileView(userID: member.id, username: member.username)
        }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
        .fullScreenCover(isPresented: $zoomAvatar) {
            AvatarZoomView(url: profile?.avatarURL,
                           name: profile.map { $0.displayName.isEmpty ? $0.username : $0.displayName } ?? (username ?? ""))
        }
        .navigationDestination(isPresented: $showSettings) {
            AccountSettingsView()
        }
        .sheet(isPresented: $showLeaderboard) {
            LeaderboardView()
                .presentationDragIndicator(.visible)
        }
        // Another member's profile: full name by the back button, with Share
        // and the ⋯ menu top-right. (Self keeps its own in-content header.)
        .toolbar {
            if !isSelf {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(memberTitle)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                }
                ToolbarItem(placement: .navigationBarTrailing) { memberShareLink }
                ToolbarItem(placement: .navigationBarTrailing) { memberMenu }
            }
        }
        .sheet(isPresented: $showInviteSheet) {
            InviteSheet()
                .presentationDetents([.large])
        }
        .sheet(isPresented: $showTop5Share) {
            TopFiveShareSheet(
                name: firstName(profile?.displayName, profile?.username) ?? "",
                handle: profile?.username ?? "",
                avatarURL: profile?.avatarURL,
                movieEntries: topEntries("movie"),
                showEntries: topEntries("tv"))
        }
        .sheet(isPresented: $showMatchShare) {
            if let pct = matchPct {
                TasteMatchShareSheet(
                    viewerName: firstName(session.profile?.displayName, session.profile?.username) ?? "You",
                    viewerAvatarURL: session.profile?.avatarURL,
                    memberName: firstName(profile?.displayName, profile?.username) ?? "",
                    memberHandle: profile?.username ?? "",
                    memberAvatarURL: profile?.avatarURL,
                    matchPct: Int(pct))
            }
        }
        .onAppear {
            // Show last-known counts instantly (no flash of 0), then refresh.
            seedCachedCounts()
            Task { await loadCounts() }
            // Fresh when you come back, without re-firing 6 queries on
            // every quick tab flick.
            guard Date().timeIntervalSince(lastLoaded) > 10 else { return }
            Task { await load() }
        }
        // Your own profile tab can appear before the session profile is ready
        // (resolvedID nil → load bails, counts stay 0); refresh once it lands.
        .onChange(of: session.profile?.id) { _, id in
            guard id != nil else { return }
            seedCachedCounts()
            Task { await loadCounts() }
            if !loaded { Task { await load() } }
        }
    }

    // MARK: Data

    /// Seed counts from the per-user cache so the stats render real numbers
    /// immediately on return instead of a 0 (or "—") while the live count loads.
    private func seedCachedCounts() {
        guard !hasCounts, let id = resolvedID,
              let cached = ProfileCountsCache.get(id) else { return }
        followerCount = cached.followers
        followingCount = cached.following
        hasCounts = true
    }

    /// Follower / following counts — cheap HEAD queries, refreshed on every
    /// appearance, cached so they never flash a stale 0.
    private func loadCounts() async {
        guard let id = resolvedID else { return }
        let supabase = SupabaseService.shared
        async let followers = supabase.followCount(of: id, direction: "following_id")
        async let following = supabase.followCount(of: id, direction: "follower_id")
        let f = await followers
        let g = await following
        followerCount = f
        followingCount = g
        hasCounts = true
        ProfileCountsCache.set(id, followers: f, following: g)
    }

    /// Everything loads in parallel — serially this took over a second of
    /// visible stagger on device.
    private func load() async {
        guard let id = resolvedID else { return }
        let supabase = SupabaseService.shared
        Task { watchingRows = await supabase.watching(for: id) }
        if !isSelf { Task { bothWatching = await supabase.mutualWatching(with: id) } }
        // Counts refresh in parallel and assign as soon as they land, so they're
        // never blocked behind the events/watches chain below.
        Task { await loadCounts() }

        async let profileTask = supabase.profile(id: id)
        async let rankingsTask = supabase.rankings(userID: id)
        async let eventsTask = supabase.events(of: id, limit: 100)
        async let watchesTask = supabase.watches(of: id)
        async let rankTask = supabase.globalRank(userID: id)

        if isSelf {
            profile = try? await profileTask.asProfile
            rankings = (try? await rankingsTask) ?? []
            movies = store.movies
            watchlistCount = store.watchlistCount
        } else {
            // None of these depend on the first batch — starting them
            // before awaiting it saves a full round-trip of latency.
            async let followingState = supabase.isFollowing(id)
            async let pendingState = supabase.followRequestPending(id)
            async let match = supabase.tasteMatch(with: id)
            async let memberWatchlistTask = supabase.watchlist(userID: id)
            async let blockedTask = supabase.blockedIDs()
            profile = try? await profileTask.asProfile
            rankings = (try? await rankingsTask) ?? []
            let rows = (try? await supabase.movies(ids: rankings.map(\.movieId))) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
            // Don't let a (possibly stale) read overwrite a follow/unfollow the
            // user just made — that race is what made follows "not stick".
            let serverFollowing = await followingState
            let serverPending = await pendingState
            if !followBusy {
                following = serverFollowing
                requested = serverPending
            }
            matchPct = await match
            blocked = await blockedTask.contains(id)
            let memberWatchlist = (try? await memberWatchlistTask) ?? []
            watchlistCount = memberWatchlist.count
            bothWantToWatch = memberWatchlist.filter { store.isOnWatchlist($0.movieId) }
        }

        // Best -> worst across buckets.
        let order = ["loved": 0, "fine": 1, "disliked": 2]
        rankings.sort { (order[$0.bucket] ?? 3, $0.position) < (order[$1.bucket] ?? 3, $1.position) }

        events = (try? await eventsTask) ?? []
        // Which of these activity events the viewer already liked, so the cards'
        // hearts are filled correctly.
        likedEventIDs = await supabase.myLikedEventIDs(events.map(\.id))
        watches = (try? await watchesTask) ?? []
        // Pull metadata for any watch (e.g. an import) the store/events don't cover.
        let missing = Set(watches.map(\.movieId)).filter { movies[$0] == nil && store.movie($0) == nil }
        if !missing.isEmpty {
            let rows = (try? await supabase.movies(ids: Array(missing))) ?? []
            for row in rows { watchMovies[row.tmdbId] = row.asMovie }
        }
        globalRank = try? await rankTask
        loaded = true
        lastLoaded = Date()
    }

    // MARK: Header (self only)

    private var header: some View {
        HStack {
            Text(firstName(profile?.displayName, profile?.username) ?? "Profile")
                .font(Theme.pageHeader)
                .lineLimit(1)
            Spacer()
            // Spacing/sizing matches the Feed header's top-right icons so the
            // two pages line up.
            HStack(spacing: 2) {
                // Leaderboard moved off the tab bar — it lives here now.
                Button { showLeaderboard = true } label: {
                    Image(systemName: "trophy").foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Leaderboard")
                ShareLink(item: "Follow me on Cini — I'm @\(profile?.username ?? "") 🎬 \(AppLinks.invite(profile?.username ?? ""))") {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
                        .contentShape(Rectangle())
                }
                Menu {
                    Button {
                        showSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button {
                        showImport = true
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
                    Image(systemName: "line.3.horizontal").foregroundStyle(Theme.ink)
                        .frame(width: 36, height: 36)
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
        }
    }

    // MARK: Top 3 — the ranking speaks for itself

    /// Letterboxd makes people hand-pick favorites; Cini already knows.
    /// The top three ranked films, always current, on every profile.
    @ViewBuilder
    private var topThree: some View {
        // Films only, ranked among films — movies and TV rank separately, so
        // a cross-kind "#1/#2/#3" would be meaningless here.
        let top = rankings.compactMap { row in
            movies[row.movieId].map { (row: row, movie: $0) }
        }
        .filter { $0.movie.mediaKind != "tv" }
        .prefix(3)
        if !top.isEmpty {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                ForEach(Array(top.enumerated()), id: \.element.row.id) { index, entry in
                    Button {
                        detailMovie = entry.movie
                    } label: {
                        PosterView(url: entry.movie.posterURL, width: hSize == .regular ? 132 : 92)
                            .overlay(alignment: .topLeading) {
                                Text("#\(index + 1)")
                                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                                    .foregroundStyle(Theme.background)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.gold))
                                    .padding(5)
                            }
                            .shadow(color: Theme.cardShadow, radius: 8, y: 4)
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Self-only: share a beautiful Top-5 card to Twitter/Instagram/etc.
    private var shareTopFiveButton: some View {
        Button {
            Haptics.tap()
            showTop5Share = true
        } label: {
            Label("Share my Top 5", systemImage: "square.and.arrow.up")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().strokeBorder(Theme.marquee.opacity(0.5), lineWidth: 1.2))
        }
        .buttonStyle(.plain)
    }


    /// Top ranked entries for one kind ("movie"/"tv"), best first, 1-based rank.
    private func topEntries(_ kind: String) -> [TopFiveShareSheet.Entry] {
        let filtered = rankings.compactMap { row -> (RankingRow, Movie)? in
            guard let m = movies[row.movieId] else { return nil }
            return ((m.mediaKind == "tv") == (kind == "tv")) ? (row, m) : nil
        }
        return filtered.prefix(5).enumerated().map { index, pair in
            TopFiveShareSheet.Entry(movie: pair.1, rank: index + 1, score: pair.0.score)
        }
    }

    // MARK: Identity + stats

    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(url: profile?.avatarURL, size: 104,
                       name: profile.map { $0.displayName.isEmpty ? $0.username : $0.displayName } ?? username)
                // Tap a real photo to see it full-screen.
                .contentShape(Circle())
                .onTapGesture {
                    guard profile?.avatarURL != nil else { return }
                    Haptics.tap()
                    zoomAvatar = true
                }
                .accessibilityAddTraits(profile?.avatarURL != nil ? .isButton : [])
            Text("@\(profile?.username ?? username ?? "—")").font(.headline)
                .lineLimit(1).truncationMode(.tail)
            Text(profile?.memberSinceText ?? "").font(.subheadline).foregroundStyle(Theme.gray)
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(.horizontal, 24)
            }
            if let links = profile?.socialLinks, !links.isEmpty {
                HStack(spacing: 8) {
                    ForEach(links, id: \.platform) { link in
                        Link(destination: link.url) {
                            HStack(spacing: 4) {
                                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                                Text(link.platform).font(.caption.weight(.semibold))
                            }
                            .foregroundStyle(Theme.marquee)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.marqueeSoft))
                        }
                    }
                }
                .padding(.top, 2)
            }
            // Another member's profile ALWAYS shows the taste match (Beli-style).
            // When it hasn't been computed yet (no overlap, brand-new follow),
            // show a gentle placeholder instead of hiding it.
            if !isSelf {
                VStack(spacing: 6) {
                    Text(matchPct.map { "\(Int($0))% match" } ?? "Rank more to see your match")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(matchPct == nil ? Theme.gray : Theme.scoreGreen)
                    if matchPct != nil {
                        Button {
                            Haptics.tap()
                            showMatchShare = true
                        } label: {
                            Label("Compare taste", systemImage: "person.2.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.marquee)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var statRow: some View {
        HStack {
            if let id = resolvedID {
                NavigationLink {
                    FollowListScreen(userID: id, direction: .followers)
                } label: {
                    stat(hasCounts ? "\(followerCount)" : "—", "Followers")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    FollowListScreen(userID: id, direction: .following)
                } label: {
                    stat(hasCounts ? "\(followingCount)" : "—", "Following")
                }
                .buttonStyle(.plain)
            } else {
                stat(hasCounts ? "\(followerCount)" : "—", "Followers")
                stat(hasCounts ? "\(followingCount)" : "—", "Following")
            }
            // Rank on Cini sits inline as a third stat (Beli-style) on every
            // profile — including your own, even though the stat card repeats it.
            Button { Haptics.tap(); showLeaderboard = true } label: {
                stat(globalRank.map { "#\($0)" } ?? "Unranked", "Rank on Cini")
            }
            .buttonStyle(.plain)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.weight(.bold))
                .foregroundStyle(Theme.ink)
            Text(label).font(.subheadline).foregroundStyle(Theme.gray)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var buttonRow: some View {
        if isSelf {
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    PillButton(title: "Edit profile", style: .outlined) {
                        Haptics.tap()
                        showEditProfile = true
                    }
                    PillShareLink(title: "Share profile",
                                  item: "Follow me on Cini — I'm @\(profile?.username ?? "") 🎬")
                    Button {
                        withAnimation(.snappy) { showSuggested.toggle() }
                        if suggested.isEmpty {
                            Task {
                                suggested = (try? await SupabaseService.shared.suggestedMembers()) ?? []
                            }
                        }
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Theme.marquee)
                            .rotationEffect(.degrees(showSuggested ? 180 : 0))
                            .padding(9)
                            .overlay(Circle().strokeBorder(Theme.marquee, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Suggested members")
                }
                if showSuggested {
                    suggestedStrip
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        } else if let id = resolvedID {
            HStack(spacing: 12) {
                PillButton(title: following ? "Following" : (requested ? "Requested" : "Follow"),
                           style: (following || requested) ? .outlined : .filled) {
                    Haptics.tap()
                    let handle = profile?.username ?? username ?? "them"
                    Task {
                        // Guards a stale in-flight load() from clobbering the
                        // state we set here (the "follow won't stick" bug).
                        followBusy = true
                        defer { followBusy = false }
                        do {
                            if following {
                                following = false
                                try await SupabaseService.shared.unfollow(id)
                                await load()   // a private account's content re-hides
                            } else if requested {
                                // Tap "Requested" to withdraw the request.
                                requested = false
                                try await SupabaseService.shared.cancelFollowRequest(id)
                            } else {
                                // Public → follows instantly; private → pending request.
                                // requestFollow's result is authoritative — trust it and
                                // DON'T reload (an immediate re-read can race the write and
                                // flip the button back to "Follow").
                                let result = try await SupabaseService.shared.requestFollow(id)
                                if result == "followed" {
                                    following = true
                                    Haptics.success()
                                    ToastCenter.shared.show("Following @\(handle) — their picks are in your feed now")
                                } else if result == "requested" {
                                    requested = true
                                    Haptics.success()
                                    ToastCenter.shared.show("Follow request sent to @\(handle)")
                                }
                            }
                        } catch {
                            await load()   // resync to the true state on failure
                        }
                    }
                }
                // Their taste, on demand — asks need a follow (the RPC
                // enforces it), so the button appears once they're a friend.
                if following && !blocked {
                    PillButton(title: "Ask for a rec", systemImage: "hand.wave",
                               style: .outlined) {
                        Haptics.tap()
                        showAskRec = true
                    }
                }
                // Report/block moved to the top-right ⋯ menu (see memberMenu).
            }
        }
    }

    /// Full name (or @handle) shown next to the back button on another
    /// member's profile.
    private var memberTitle: String {
        let dn = (profile?.displayName ?? "").trimmingCharacters(in: .whitespaces)
        return dn.isEmpty ? "@\(profile?.username ?? username ?? "")" : dn
    }

    /// Share a member's profile (top-right of their page).
    private var memberShareLink: some View {
        ShareLink(item: "Check out @\(profile?.username ?? username ?? "") on Cini 🎬 \(AppLinks.invite(profile?.username ?? username ?? ""))") {
            Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.ink)
        }
    }

    /// Report / block, in the top-right ⋯ (moved off the button row).
    @ViewBuilder private var memberMenu: some View {
        if let id = resolvedID {
            Menu {
                Button(role: .destructive) {
                    Task {
                        let ok = await SupabaseService.shared.report(
                            kind: "member", subjectID: id.uuidString)
                        if ok {
                            reported = true
                            Haptics.success()
                            ToastCenter.shared.show("Reported — we'll review it")
                        } else { ToastCenter.shared.saveFailed() }
                    }
                } label: {
                    Label(reported ? "Reported" : "Report member", systemImage: "flag")
                }
                .disabled(reported)
                Button(role: .destructive) {
                    if blocked {
                        Task {
                            try? await SupabaseService.shared.unblock(id)
                            ToastCenter.shared.show("Unblocked")
                            blocked = false
                            await load()
                        }
                    } else {
                        showBlockConfirm = true
                    }
                } label: {
                    Label(blocked ? "Unblock member" : "Block member",
                          systemImage: "hand.raised")
                }
            } label: {
                Image(systemName: "ellipsis").foregroundStyle(Theme.ink)
            }
            .alert("Block @\(profile?.username ?? username ?? "member")?", isPresented: $showBlockConfirm) {
                Button("Block", role: .destructive) {
                    Task {
                        do {
                            try await SupabaseService.shared.block(id)
                            Haptics.success()
                            ToastCenter.shared.show("Blocked — their content is hidden everywhere")
                            blocked = true
                            await load()
                        } catch {
                            ToastCenter.shared.saveFailed()
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You won't see each other's rankings, notes, or activity, and they won't be able to follow you or comment on your activity.")
            }
        }
    }

    /// Horizontal "Suggested for you" — quick follows without leaving
    /// the profile.
    private var suggestedStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(suggested.prefix(12)) { member in
                    VStack(spacing: 8) {
                        NavigationLink {
                            MemberProfileView(userID: member.id, username: member.username)
                        } label: {
                            VStack(spacing: 6) {
                                AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 56,
                                           name: member.displayName.isEmpty ? member.username : member.displayName)
                                Text(firstName(member.displayName, member.username) ?? member.username)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                Text(member.matchPct.map { "\(Int($0))% match" }
                                     ?? "\(member.watched) films")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.gray)
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task {
                                // Optimistic flip, reverted if the call fails.
                                if followedSuggested.contains(member.id) {
                                    followedSuggested.remove(member.id)
                                    do { try await SupabaseService.shared.unfollow(member.id) }
                                    catch { followedSuggested.insert(member.id); ToastCenter.shared.saveFailed() }
                                } else if requestedSuggested.contains(member.id) {
                                    requestedSuggested.remove(member.id)
                                    do { try await SupabaseService.shared.cancelFollowRequest(member.id) }
                                    catch { requestedSuggested.insert(member.id); ToastCenter.shared.saveFailed() }
                                } else {
                                    do {
                                        // Public follows instantly; private returns "requested".
                                        let result = try await SupabaseService.shared.requestFollow(member.id)
                                        if result == "requested" { requestedSuggested.insert(member.id) }
                                        else { followedSuggested.insert(member.id) }
                                    }
                                    catch { ToastCenter.shared.saveFailed() }
                                }
                            }
                        } label: {
                            let isFollowing = followedSuggested.contains(member.id)
                            let isRequested = requestedSuggested.contains(member.id)
                            Text(isFollowing ? "Following" : (isRequested ? "Requested" : "Follow"))
                                .font(.caption.weight(.bold))
                                .foregroundStyle(isFollowing || isRequested ? Theme.marquee : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(isFollowing || isRequested
                                                           ? Theme.marqueeSoft : Theme.velvet))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .frame(width: 118)
                    .background(
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Theme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 16)
                                .strokeBorder(Theme.hairline, lineWidth: 1))
                    )
                }
                if suggested.isEmpty {
                    Text("Suggestions appear as members join — invite your crew!")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .padding(.vertical, 20)
                }
            }
        }
        .scrollClipDisabled()
    }

    // MARK: List rows (Beli: Been / Want to Try / Recs for You)

    private var listRows: some View {
        isSelf ? AnyView(ownListRows) : AnyView(memberListRows)
    }

    /// Your own profile: Watched · Want to Watch · Watching · Recs — each jumps
    /// to that page in the Lists tab (no separate "Lists" row, since these
    /// already land there).
    private var ownListRows: some View {
        VStack(spacing: 0) {
            jumpRow(icon: "checkmark.circle", title: "Watched", count: rankings.count, tab: .watched)
            Divider()
            jumpRow(icon: "bookmark", title: "Want to Watch", count: watchlistCount, tab: .watchlist)
            Divider()
            jumpRow(icon: "play.tv", title: "Watching", count: watchingRows.count, tab: .watching)
            Divider()
            Button { tabRouter.selection = .swipe } label: {
                listRow(icon: "heart", title: "Recs for You", count: nil)
            }
            .buttonStyle(.plain)
        }
    }

    private func jumpRow(icon: String, title: String, count: Int?,
                         tab: YourListsView.SubTab) -> some View {
        Button {
            tabRouter.pendingListsTab = tab
            tabRouter.selection = .lists
        } label: {
            listRow(icon: icon, title: title, count: count)
        }
        .buttonStyle(.plain)
    }

    /// A friend's profile: their Watched · Want to Watch · Watching in the same
    /// UI as your own (pushed, so the back arrow returns here), then the two
    /// "both" overlap screens.
    private var memberListRows: some View {
        VStack(spacing: 0) {
            // Watched / Want to Watch / Watching open ONE connected tabbed page
            // (like My Lists) with a single back arrow to this profile.
            NavigationLink {
                memberLists(.watched)
            } label: {
                listRow(icon: "checkmark.circle", title: "Watched", count: rankings.count)
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink {
                memberLists(.watchlist)
            } label: {
                listRow(icon: "bookmark", title: "Want to Watch", count: watchlistCount)
            }
            .buttonStyle(.plain)
            if !watchingRows.isEmpty {
                Divider()
                NavigationLink {
                    memberLists(.watching)
                } label: {
                    listRow(icon: "play.tv", title: "Watching", count: watchingRows.count)
                }
                .buttonStyle(.plain)
            }
            if !bothWantToWatch.isEmpty {
                Divider()
                NavigationLink {
                    BothWantToWatchScreen(username: profile?.username ?? username ?? "them",
                                          rows: bothWantToWatch, overlap: overlapInfo)
                } label: {
                    listRow(icon: "person.2", title: "You both want to watch",
                            count: bothWantToWatch.count)
                }
                .buttonStyle(.plain)
            }
            if !bothWatching.isEmpty {
                Divider()
                NavigationLink {
                    WatchingListScreen(title: "You both are watching", rows: bothWatching,
                                       overlap: overlapInfo)
                } label: {
                    listRow(icon: "play.tv.fill", title: "You both are watching",
                            count: bothWatching.count)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func memberLists(_ initial: MemberListsView.Tab) -> some View {
        MemberListsView(
            userID: resolvedID,
            title: profile?.displayName ?? username.map { "@\($0)" } ?? "Lists",
            rankings: rankings, movies: movies, watchingRows: watchingRows,
            lockedHint: lockedHint, loaded: loaded, initial: initial)
    }

    /// The overlapping-avatars header data for the "both" screens.
    private var overlapInfo: OverlapData {
        OverlapData(
            myAvatar: session.profile?.avatarURL,
            myName: session.profile?.displayName ?? session.profile?.username,
            theirAvatar: profile?.avatarURL,
            theirName: profile?.displayName ?? profile?.username ?? username,
            onAddFriend: {
                tabRouter.openMembersSearch = true
                tabRouter.selection = .search
            })
    }

    private var lockedHint: String? {
        (!isSelf && profile?.isPrivate == true && !following)
            ? "This account is private — follow to see their rankings." : nil
    }

    private func listRow(icon: String, title: String, count: Int?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 30)
                .foregroundStyle(Theme.ink)
            Text(title).font(.headline).foregroundStyle(Theme.ink)
            Spacer()
            if let count {
                Text("\(count)").font(.headline).foregroundStyle(Theme.ink)
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
        }
        .padding(.vertical, 14)
        // The stretch between title and count is empty space — without an
        // explicit shape only the icon/text/arrow register taps.
        .contentShape(Rectangle())
    }

    // MARK: Stat cards (Rank on Cini · Current Streak)

    private var statCards: some View {
        HStack(spacing: 12) {
            Button { Haptics.tap(); showLeaderboard = true } label: {
                HairlineCard {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "trophy").font(.title3).foregroundStyle(Theme.marquee)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                .foregroundStyle(Theme.gray)
                        }
                        Text("Rank on Cini").font(.subheadline).foregroundStyle(Theme.marquee)
                        Text(globalRank.map { "#\($0)" } ?? "Unranked")
                            .font(globalRank == nil ? .headline : .title2.weight(.bold))
                            .foregroundStyle(Theme.marquee)
                        if globalRank == nil && isSelf {
                            Text("Rank a title to enter the board")
                                .font(.caption2)
                                .foregroundStyle(Theme.gray)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .buttonStyle(.plain)
            HairlineCard {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "flame.fill").font(.title3).foregroundStyle(Theme.gold)
                    Text("Current Streak").font(.subheadline).foregroundStyle(Theme.marquee)
                    let weeks = profile?.streakWeeks ?? 0
                    Text(weeks == 1 ? "1 week" : "\(weeks) weeks")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.marquee)
                    if isSelf, let p = profile {
                        if p.streakWeeks == 0 {
                            Text("Rank one title to light the flame")
                                .font(.caption2)
                                .foregroundStyle(Theme.gray)
                        } else if !p.hasLoggedThisWeek {
                            Text("Rank this week to keep it")
                                .font(.caption2)
                                .foregroundStyle(Theme.gold)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        // Whichever card has the extra caption line sets the height for
        // BOTH — side-by-side cards must never be different sizes.
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Activity | Taste Profile tabs

    private var profileTabs: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                tabButton("Activity", icon: "list.bullet.rectangle", index: 0)
                tabButton("Taste Profile", icon: "chart.bar", index: 1)
            }
            .padding(.bottom, 4)
            Divider()
            if profileTab == 0 {
                activityContent
            } else {
                tasteContent
            }
        }
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation(.snappy) { profileTab = index }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.caption)
                    Text(title).font(.subheadline.weight(profileTab == index ? .bold : .regular))
                }
                .foregroundStyle(profileTab == index ? Theme.ink : Theme.gray)
                Rectangle()
                    .fill(profileTab == index ? Theme.gold : .clear)
                    .frame(height: 2)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    /// Activity is now the single history surface: social events (ranked,
    /// saved, rec'd) merged with diary watches (incl. Letterboxd imports), newest
    /// first. A watch on the same day a social event already covers is dropped so
    /// nothing double-lists.
    private enum ActivityItem: Identifiable {
        case event(FeedEventRow)
        case watch(WatchRow)
        var id: String {
            switch self {
            case .event(let e): return "e-\(e.id)"
            case .watch(let w): return "w-\(w.id)"
            }
        }
    }

    private var activityItems: [ActivityItem] {
        let day = DateFormatter.posixDay
        var covered = Set<String>()
        for e in events { if let m = e.movieId { covered.insert("\(m)@\(day.string(from: e.createdAt))") } }
        var dated: [(Date, ActivityItem)] = events.map { ($0.createdAt, .event($0)) }
        for w in watches where !covered.contains("\(w.movieId)@\(w.watchedOn)") {
            dated.append((day.date(from: w.watchedOn) ?? .distantPast, .watch(w)))
        }
        return dated.sorted { $0.0 > $1.0 }.map(\.1)
    }

    @ViewBuilder
    private var activityContent: some View {
        let items = activityItems
        if items.isEmpty && loaded {
            if let lockedHint {
                Text(lockedHint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else if isSelf {
                EmptyStateView(
                    icon: "film.stack",
                    title: "Build your taste",
                    message: "Rank or import something you've watched and your stats, top picks, and activity fill in right here.",
                    actionTitle: "Rank a title") { tabRouter.selection = .search }
            } else {
                Text(username.map { "@\($0) is just getting started — no rankings yet." } ?? "No rankings yet — your taste starts here.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            }
        }
        VStack(spacing: 12) {
            ForEach(showAllActivity ? items : Array(items.prefix(12))) { item in
                activityRow(item)
            }
        }
        if !showAllActivity && items.count > 12 {
            Button("See all \(items.count) updates") {
                withAnimation(.snappy) { showAllActivity = true }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.marquee)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
        }
    }

    @ViewBuilder
    private func activityRow(_ item: ActivityItem) -> some View {
        switch item {
        case .event(let event):
            if event.movieId != nil {
                // The same interactive card as the feed — like, comment, share,
                // save — so you can engage with activity right from a profile.
                FeedCard(
                    event: event,
                    initiallyLiked: likedEventIDs.contains(event.id),
                    onOpenMovie: { detailMovie = $0 },
                    onQuickAdd: { logMovie = $0 },
                    onOpenMember: { _ in },   // already on this profile
                    onOpenComments: { ev, ctx in commentsLink = CommentsLink(id: ev.id, context: ctx) },
                    commentCountOverride: commentCountOverrides[event.id]
                )
            } else {
                // No movie attached (rare "shared an update") — a plain line.
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(activityLine(event)).font(.subheadline).lineLimit(2)
                        Text(event.createdAt.formatted(.relative(presentation: .named)))
                            .font(.caption).foregroundStyle(Theme.gray)
                    }
                    Spacer()
                }
                .padding(.vertical, 8)
            }
        case .watch(let watch):
            let movie = watchMovies[watch.movieId] ?? movies[watch.movieId] ?? store.movie(watch.movieId)
            HStack(spacing: 12) {
                if let movie { PosterView(url: movie.posterURL, width: 36) }
                VStack(alignment: .leading, spacing: 2) {
                    (Text("Watched ").foregroundStyle(Theme.gray)
                     + Text(movie?.title ?? "a title").fontWeight(.semibold).foregroundStyle(Theme.ink))
                        .font(.subheadline).lineLimit(2)
                    Text(diaryDayLabel(watch.watchedOn))
                        .font(.caption).foregroundStyle(Theme.gray)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if let movie { store.cache(movie); detailMovie = movie } }
        }
    }

    /// "Jun 11, 2026" from a date-only string; falls back to the raw string.
    private func diaryDayLabel(_ day: String) -> String {
        guard let date = DateFormatter.posixDay.date(from: day) else { return day }
        return date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    private func activityLine(_ event: FeedEventRow) -> AttributedString {
        let handle = profile?.username ?? username
        let who = isSelf ? "You" : (handle.map { "@\($0)" } ?? "Someone")
        let title = event.movies?.title ?? "a movie"
        let text: String
        switch event.eventType {
        case "ranked": text = "\(who) ranked **\(title)**"
        case "watchlisted": text = "\(who) wants to watch **\(title)**"
        case "noted": text = "\(who) wrote about **\(title)**"
        default: text = "\(who) shared an update"
        }
        return (try? AttributedString(markdown: text)) ?? AttributedString(text)
    }

    private var taste: TasteSummary {
        TasteSummary(rankings: rankings, movies: movies)
    }

    @ViewBuilder
    private var tasteContent: some View {
        if rankings.isEmpty {
            if let lockedHint {
                Text(lockedHint)
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                EmptyStateView(
                    icon: "chart.pie.fill",
                    title: "See what you like",
                    message: isSelf ? "Rank a few titles and we'll show what you're into."
                                    : "Nothing to show here yet.")
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                // A plain-language summary so the taste profile reads as an
                // identity ("here's who I am") before the breakdown.
                if let headline = taste.headline {
                    Text(headline)
                        .font(Theme.serif(20))
                        .foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 0) {
                    sentimentStat(taste.lovedCount, Theme.sentimentLoved, "Liked")
                    sentimentStat(taste.fineCount, Theme.sentimentFine, "Fine")
                    sentimentStat(taste.dislikedCount, Theme.sentimentDisliked, "Disliked")
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
                    .foregroundStyle(Theme.marquee)
                }
            }
            .padding(.vertical, 16)
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
}

// MARK: - Pushed list screens

/// Beli-style rich row shared by the pushed list screens: rank number,
/// poster, bold title, metadata + context lines, then quick actions
/// (log / save) and an optional score badge.
struct ActivityMovieRow: View {
    var rank: Int?
    let movie: Movie
    var context: String?
    var contextColor: Color = Theme.gray
    var score: Double?
    var showsQuickActions = false
    var onLog: ((Movie) -> Void)?

    @Environment(RankingStore.self) private var store
    @State private var showSaveSheet = false

    var body: some View {
        HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 52)
            // Match My Lists rows: inline "N. Title" rank (when ranked), heavier
            // title, and the genre·year metadata line — so a member's list looks
            // exactly like your own.
            VStack(alignment: .leading, spacing: 3) {
                Text(rank.map { "\($0). \(movie.title)" } ?? movie.title)
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Text(movie.metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                    .lineLimit(1)
                if !movie.bylineText.isEmpty {
                    Text(movie.bylineText)
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(1)
                }
                if let context {
                    Text(context)
                        .font(.caption2)
                        .foregroundStyle(contextColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            // Score top-right, (+)/bookmark bottom-right — same corners
            // as every other card in the app.
            VStack(alignment: .trailing, spacing: 6) {
                if let score {
                    ScoreBadge(score: score, size: 44)
                }
                if showsQuickActions {
                    if store.isWatched(movie.tmdbID) {
                        Image(systemName: "checkmark.circle")
                            .font(.title3)
                            .foregroundStyle(Theme.scoreGreen.opacity(0.85))
                    } else {
                        quickActions
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }

    private var quickActions: some View {
        HStack(spacing: 16) {
            if let onLog {
                Button {
                    onLog(movie)
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.title3)
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Rank \(movie.title)")
            }
            Button {
                bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
            } label: {
                Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(store.isOnWatchlist(movie.tmdbID) ? "On your Want to Watch" : "Bookmark to Want to Watch")
        }
        .sheet(isPresented: $showSaveSheet) {
            SaveToListSheet(movie: movie)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

/// A user's ranked list, pushed from the Watched row.
struct RankedListScreen: View {
    let title: String
    let rankings: [RankingRow]
    let movies: [Int: Movie]
    var isSelf = true
    /// False while the parent is still fetching (member profiles), so the empty
    /// text doesn't flash before the rankings arrive.
    var loaded = true
    var emptyHint: String?
    // When embedded in MemberListsView, taps route to the parent's nav and this
    // screen drops its own title/destination so the tabs share one back arrow.
    var openDetail: ((Movie) -> Void)? = nil
    var openLog: ((Movie) -> Void)? = nil
    /// When set (e.g. embedded under a parent's Movies/TV switcher), this screen
    /// shows only that kind and hides its own segmented control.
    var forcedCategory: MediaCategory? = nil
    private var embedded: Bool { openDetail != nil }

    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var filters = MovieFilters()
    // Movies and TV are ranked apart, so the list is split too — #1 means
    // #1 among that kind, never a mixed number.
    @State private var categoryIndex = 0
    @State private var pickedDefault = false
    private var category: MediaCategory { forcedCategory ?? (categoryIndex == 0 ? .movies : .tvShows) }

    private func rows(in category: MediaCategory) -> [RankingRow] {
        rankings.filter { movies[$0.movieId].map(category.matches) ?? false }
    }

    /// Rank numbers come from the full kind list (so "#14" stays #14 while
    /// searching), within the selected media kind.
    private var visible: [(index: Int, row: RankingRow)] {
        let all = Array(rows(in: category).enumerated()).map { (index: $0.offset, row: $0.element) }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { entry in
            guard let movie = movies[entry.row.movieId] else { return true }
            guard filters.passes(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    var body: some View {
        let content = scrollBody
        if embedded {
            content
        } else {
            content
                .navigationTitle("\(title) (\(rankings.count))")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $detailMovie) { movie in
                    MovieDetailView(movie: movie)
                }
                .fullScreenCover(item: $logMovie) { movie in
                    LogFlowView(movie: movie)
                }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Split by kind whenever there are both — movies and TV are
                // ranked separately. Hidden when a parent already drives the kind.
                if forcedCategory == nil && !rows(in: .movies).isEmpty && !rows(in: .tvShows).isEmpty {
                    SegmentedPillControl(segments: ["Movies", "TV Shows"], selection: $categoryIndex)
                        .padding(.bottom, 12)
                }
                HStack {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.bold))
                        Text("Score").font(.subheadline.weight(.bold))
                    }
                    .foregroundStyle(Theme.marquee)
                    Spacer()
                    Button {
                        withAnimation(.snappy) { showSearch.toggle() }
                        if !showSearch { searchText = "" }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Search this list")
                }
                .padding(.bottom, 2)
                // Same filter pills as My Lists — on anyone's list.
                MovieFilterBar(filters: $filters, movies: Array(movies.values))
                    .padding(.horizontal, -16)
                if showSearch {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                        TextField("Filter this list", text: $searchText)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear search")
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    .padding(.bottom, 10)
                }
                if !loaded && rankings.isEmpty {
                    ListSkeleton(rows: 8)
                } else if rankings.isEmpty {
                    Text(emptyHint ?? "Nothing here yet.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else if visible.isEmpty {
                    Text(searchText.isEmpty ? "No titles match these filters."
                                            : "No titles match \"\(searchText)\".")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
                ForEach(visible, id: \.row.id) { index, row in
                    if let movie = movies[row.movieId] {
                        ActivityMovieRow(
                            rank: index + 1,
                            movie: movie,
                            context: "Ranked \(row.createdAt.formatted(.relative(presentation: .named)))",
                            score: row.score,
                            showsQuickActions: !isSelf,
                            onLog: { (openLog ?? { logMovie = $0 })($0) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { (openDetail ?? { detailMovie = $0 })(movie) }
                        Divider()
                    }
                }
            }
            .padding(16)
        }
        .scrollDismissesKeyboard(.immediately)
        .nativeContentWidth()
        .background(Theme.background)
        .onAppear {
            // Open on the kind that actually has titles (e.g. a TV-only list
            // shouldn't land on an empty Movies tab). Skipped when the kind is
            // driven by a parent.
            guard forcedCategory == nil, !pickedDefault else { return }
            pickedDefault = true
            if rows(in: .movies).isEmpty && !rows(in: .tvShows).isEmpty { categoryIndex = 1 }
        }
    }
}

/// A user's watchlist, pushed from the Watchlist row. Your own list reads
/// straight from the store so removing a save updates the rows live.
struct WatchlistScreen: View {
    let userID: UUID?
    let isSelf: Bool
    var openDetail: ((Movie) -> Void)? = nil
    var openLog: ((Movie) -> Void)? = nil
    var categoryFilter: MediaCategory? = nil      // restrict to Movies or TV when driven by a parent
    private var embedded: Bool { openDetail != nil }

    @Environment(RankingStore.self) private var store
    @State private var fetched: [WatchlistRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var predicted: [Int: Double] = [:]
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var listLoaded = false
    @State private var filters = MovieFilters()

    /// (movieID, savedAt) — live store for self, fetched rows for others.
    private var entries: [(movieID: Int, savedAt: Date)] {
        let all = isSelf ? store.watchlist.map { ($0.movieID, $0.createdAt) }
                         : fetched.map { ($0.movieId, $0.createdAt) }
        return all.filter { entry in
            guard let movie = movies[entry.0] ?? store.movie(entry.0) else { return true }
            return filters.passes(movie) && (categoryFilter?.matches(movie) ?? true)
        }
    }

    var body: some View {
        let content = scrollBody
        if embedded {
            content
        } else {
            content
                .navigationTitle("Want to Watch (\(entries.count))")
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $detailMovie) { movie in
                    MovieDetailView(movie: movie)
                }
                .fullScreenCover(item: $logMovie) { movie in
                    LogFlowView(movie: movie)
                }
        }
    }

    private var scrollBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Same filter pills as My Lists — on anyone's list.
                MovieFilterBar(filters: $filters,
                               movies: isSelf
                                   ? store.watchlist.compactMap { store.movie($0.movieID) }
                                   : Array(movies.values))
                    .padding(.horizontal, -16)
                if entries.isEmpty {
                    if isSelf || listLoaded {
                        Text(filters.isActive ? "No titles match these filters."
                                              : "Nothing on your Want to Watch list yet.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    } else {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 32)
                    }
                }
                ForEach(entries, id: \.movieID) { entry in
                    if let movie = movies[entry.movieID] ?? store.movie(entry.movieID) {
                        ActivityMovieRow(
                            movie: movie,
                            context: watchlistContext(movie: movie, savedAt: entry.savedAt),
                            contextColor: movie.availabilityText == nil ? Theme.gray : Theme.marquee,
                            score: predicted[entry.movieID],
                            showsQuickActions: true,
                            onLog: { (openLog ?? { logMovie = $0 })($0) }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { (openDetail ?? { detailMovie = $0 })(movie) }
                        Divider()
                    }
                }
            }
            .padding(16)
        }
        .nativeContentWidth()
        .background(Theme.background)
        .task {
            if !isSelf, let userID {
                fetched = (try? await SupabaseService.shared.watchlist(userID: userID)) ?? []
                let rows = (try? await SupabaseService.shared.movies(ids: fetched.map(\.movieId))) ?? []
                for row in rows { movies[row.tmdbId] = row.asMovie }
            }
            listLoaded = true
            // Rec Score: how much we think YOU'LL like each saved title.
            predicted = await SupabaseService.shared.predictedScores(
                movieIDs: entries.map(\.movieID))
        }
    }

    private func watchlistContext(movie: Movie, savedAt: Date) -> String {
        if let availability = movie.availabilityText { return availability }
        return "Added \(savedAt.formatted(.relative(presentation: .named)))"
    }
}

/// Movies on both your watchlist and the member's — the "Places you both
/// want to try" row from Beli, pushed from a member profile.
struct BothWantToWatchScreen: View {
    let username: String
    /// The member's watchlist rows that are also on the viewer's watchlist.
    let rows: [WatchlistRow]
    var overlap: OverlapData?

    @Environment(RankingStore.self) private var store
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let overlap {
                    OverlapHeader(overlap: overlap,
                                  title: "You both want to watch",
                                  subtitle: "On both your Want to Watch lists — perfect for a watch night.")
                }
                if rows.isEmpty {
                    Text("No overlap yet — save a few of @\(username)'s Want to Watch picks and they show up here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                }
                ForEach(rows) { row in
                    // Intersection rows are on the viewer's own watchlist,
                    // so the store always has their metadata.
                    if let movie = store.movie(row.movieId) {
                        ActivityMovieRow(
                            movie: movie,
                            context: movie.availabilityText ?? "You both saved this",
                            contextColor: Theme.marquee,
                            showsQuickActions: true,
                            onLog: { logMovie = $0 }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                        Divider()
                    }
                }
            }
            .padding(16)
        }
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle("You Both Want to Watch")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
    }
}

/// Currently-watching shows as a compact vertical list, pushed from a profile
/// list row (was a big poster shelf at the top of the profile).
struct WatchingListScreen: View {
    let title: String
    let rows: [WatchingRow]
    /// When set, shows the overlapping-avatars header (the "you both" screens).
    var overlap: OverlapData? = nil
    var openDetail: ((Movie) -> Void)? = nil
    private var embedded: Bool { openDetail != nil }

    @Environment(RankingStore.self) private var store
    @State private var detailMovie: Movie?

    var body: some View {
        let content = listBody
        if embedded {
            content
        } else {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(item: $detailMovie) { movie in
                    MovieDetailView(movie: movie)
                }
        }
    }

    private var listBody: some View {
        List {
            if let overlap {
                OverlapHeader(overlap: overlap,
                              title: "You both are watching",
                              subtitle: "Shows you're both mid-binge on — line up your next episode together.")
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            ForEach(rows) { row in
                Button { open(row.showId) } label: {
                    HStack(spacing: 12) {
                        PosterView(url: poster(row.posterPath), width: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink).lineLimit(1)
                            if let label = episodeLabel(season: row.season, episode: row.episode) {
                                Text(label).font(.caption).foregroundStyle(Theme.marquee)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .nativeContentWidth()
        .background(Theme.background)
    }

    private func poster(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }

    private func open(_ showID: Int) {
        Task {
            if let movie = try? await TMDBService.shared.details(for: showID) {
                store.cache(movie)
                (openDetail ?? { detailMovie = $0 })(movie)
            }
        }
    }
}

/// Another member's lists as one connected, tabbed page — the same experience
/// as My Lists (Watched / Want to Watch / Watching, switchable in place), but
/// pushed from their profile so a single back arrow returns there.
struct MemberListsView: View {
    let userID: UUID?
    let title: String                 // their name / @handle, shown in the nav bar
    let rankings: [RankingRow]
    let movies: [Int: Movie]
    let watchingRows: [WatchingRow]
    let lockedHint: String?
    /// False while the parent profile is still fetching, so the Watched tab
    /// shows a skeleton instead of flashing "Nothing here yet".
    var loaded: Bool = true
    @State private var category: MediaCategory = .movies
    @State private var subTab: Tab
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    enum Tab: String, CaseIterable { case watched = "Watched", watchlist = "Want to Watch", watching = "Watching" }

    init(userID: UUID?, title: String, rankings: [RankingRow], movies: [Int: Movie],
         watchingRows: [WatchingRow], lockedHint: String?, loaded: Bool = true, initial: Tab = .watched) {
        self.userID = userID; self.title = title; self.rankings = rankings
        self.movies = movies; self.watchingRows = watchingRows; self.lockedHint = lockedHint
        self.loaded = loaded
        _subTab = State(initialValue: initial)
    }

    // Same shape as My Lists: Movies/TV up top, then sub-tabs. Watching is
    // TV-only (and only when they're watching something).
    private var tabs: [Tab] {
        var t: [Tab] = [.watched, .watchlist]
        if category == .tvShows && !watchingRows.isEmpty { t.append(.watching) }
        return t
    }
    private var active: Tab { tabs.contains(subTab) ? subTab : .watched }

    var body: some View {
        VStack(spacing: 0) {
            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { category == .tvShows ? 1 : 0 },
                                   set: { category = $0 == 1 ? .tvShows : .movies
                                          if !tabs.contains(subTab) { subTab = .watched } }))
                .screenHPadding().padding(.top, 10)
            subTabsRow.padding(.top, 12)
            Divider().padding(.top, 6)
            switch active {
            case .watched:
                RankedListScreen(title: "Watched", rankings: rankings, movies: movies,
                                 isSelf: false, loaded: loaded, emptyHint: lockedHint,
                                 openDetail: { detailMovie = $0 }, openLog: { logMovie = $0 },
                                 forcedCategory: category)
            case .watchlist:
                WatchlistScreen(userID: userID, isSelf: false,
                                openDetail: { detailMovie = $0 }, openLog: { logMovie = $0 },
                                categoryFilter: category)
            case .watching:
                WatchingListScreen(title: "Watching", rows: watchingRows,
                                   openDetail: { detailMovie = $0 })
            }
        }
        .nativeContentWidth()
        .background(Theme.background)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in MovieDetailView(movie: movie) }
        .fullScreenCover(item: $logMovie) { movie in LogFlowView(movie: movie) }
    }

    // Text-underline sub-tabs, matching My Lists.
    private var subTabsRow: some View {
        HStack(spacing: 22) {
            ForEach(tabs, id: \.self) { tab in
                let isOn = active == tab
                Button { withAnimation(.snappy) { subTab = tab } } label: {
                    VStack(spacing: 6) {
                        Text(tab.rawValue)
                            .font(.subheadline.weight(isOn ? .bold : .regular))
                            .foregroundStyle(isOn ? Theme.ink : Theme.gray)
                        Rectangle().fill(isOn ? Theme.ink : .clear).frame(height: 2)
                    }
                    .fixedSize()
                }
                .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .screenHPadding()
    }
}

/// The two profile pics (you + the friend) for an overlap screen, plus a way
/// to bring in another friend.
struct OverlapData {
    let myAvatar: URL?
    let myName: String?
    let theirAvatar: URL?
    let theirName: String?
    var onAddFriend: () -> Void
}

/// Overlapping avatars + a "+" to add another friend, over a title/subtitle —
/// the header for the "you both" overlap screens (no map; our design).
struct OverlapHeader: View {
    let overlap: OverlapData
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: -14) {
                AvatarView(url: overlap.myAvatar, size: 54, name: overlap.myName)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 3))
                    .zIndex(2)
                AvatarView(url: overlap.theirAvatar, size: 54, name: overlap.theirName)
                    .overlay(Circle().strokeBorder(Theme.background, lineWidth: 3))
                    .zIndex(1)
                Button(action: overlap.onAddFriend) {
                    Image(systemName: "plus")
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Theme.marquee)
                        .frame(width: 54, height: 54)
                        .background(Circle().fill(Theme.fill))
                        .overlay(Circle().strokeBorder(Theme.marquee.opacity(0.5),
                                                       style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
                .accessibilityLabel("Compare with another friend")
            }
            Text(title)
                .font(Theme.serif(26)).foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.subheadline).foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .padding(.bottom, 14)
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

    /// A one-line, plain-language taste descriptor for the top of the profile's
    /// Taste tab — built from the same genres/decade shown below it, so the
    /// headline can never contradict the chart. Nil until there's enough signal.
    var headline: String? {
        let genres = topGenres.prefix(2).map(\.name)
        guard !genres.isEmpty else { return nil }
        let genrePart = genres.count == 1 ? genres[0] : "\(genres[0]) & \(genres[1])"
        if let decade = favoriteDecade {
            return "Big on \(genrePart), with a soft spot for the \(decade)s."
        }
        return "Big on \(genrePart)."
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

/// Full-screen viewer for a profile photo. Tap anywhere, the ✕, or swipe down
/// to dismiss — a plain, robust image viewer (no fragile custom transitions).
struct AvatarZoomView: View {
    let url: URL?
    let name: String

    @Environment(\.dismiss) private var dismiss
    @State private var drag: CGFloat = 0

    private var dimmed: Double { 1 - min(abs(drag) / 600, 0.7) }

    var body: some View {
        ZStack {
            Color.black.opacity(dimmed).ignoresSafeArea()
            Group {
                CachedAsyncImage(url: url) { image in
                    image.resizable().scaledToFit()
                } placeholder: {
                    // No photo loaded yet → large initials, never a blank screen.
                    AvatarView(url: nil, size: 180, name: name)
                }
            }
            .padding(28)
            .offset(y: drag)
            .gesture(
                DragGesture()
                    .onChanged { drag = $0.translation.height }
                    .onEnded { value in
                        if abs(value.translation.height) > 120 { dismiss() }
                        else { withAnimation(.snappy) { drag = 0 } }
                    }
            )
        }
        // Tap the backdrop (or photo) to close.
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(12)
                    .background(Circle().fill(.black.opacity(0.45)))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.top, 12)
            .accessibilityLabel("Close")
        }
        .statusBarHidden()
    }
}
