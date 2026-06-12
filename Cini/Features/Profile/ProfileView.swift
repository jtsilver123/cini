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
    @Environment(TabRouter.self) private var tabRouter

    @State private var profile: Profile?
    @State private var rankings: [RankingRow] = []
    @State private var movies: [Int: Movie] = [:]
    @State private var events: [FeedEventRow] = []
    @State private var followerCount = 0
    @State private var followingCount = 0
    @State private var following = false
    @State private var blocked = false
    @State private var reported = false
    @State private var showBlockConfirm = false
    @State private var showAskRec = false
    @State private var matchPct: Double?
    @State private var globalRank: Int?
    @State private var watchlistCount = 0
    /// Member's watchlist rows also on the viewer's list (member profiles only).
    @State private var bothWantToWatch: [WatchlistRow] = []
    @State private var profileTab = 0   // 0 = Activity, 1 = Taste Profile
    @State private var showImport = false
    @State private var showEditProfile = false
    @State private var showSettings = false
    @State private var showInviteSheet = false
    @State private var showSuggested = false
    @State private var suggested: [SuggestedMember] = []
    @State private var followedSuggested: Set<UUID> = []
    @State private var detailMovie: Movie?
    @State private var loaded = false
    @State private var lastLoaded: Date = .distantPast
    @State private var showLogoutConfirm = false

    private var isSelf: Bool { userID == nil || userID == session.profile?.id }
    private var resolvedID: UUID? { userID ?? session.profile?.id }

    var body: some View {
        // The self header (name, share, menu) stays frozen; content scrolls.
        VStack(spacing: 0) {
            if isSelf {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .background(Theme.background)
            }
            ScrollView {
                VStack(spacing: 18) {
                    identity
                    topThree
                    statRow
                    buttonRow
                    listRows
                    statCards
                    profileTabs
                }
                .padding(16)
            }
            .refreshable { await load() }
        }
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
        .navigationDestination(isPresented: $showSettings) {
            AccountSettingsView()
        }
        .sheet(isPresented: $showInviteSheet) {
            InviteSheet()
                .presentationDetents([.medium])
        }
        .onAppear {
            // Fresh when you come back, without re-firing 6 queries on
            // every quick tab flick.
            guard Date().timeIntervalSince(lastLoaded) > 10 else { return }
            Task { await load() }
        }
    }

    // MARK: Data

    /// Everything loads in parallel — serially this took over a second of
    /// visible stagger on device.
    private func load() async {
        guard let id = resolvedID else { return }
        let supabase = SupabaseService.shared

        async let profileTask = supabase.profile(id: id)
        async let rankingsTask = supabase.rankings(userID: id)
        async let eventsTask = supabase.events(of: id)
        async let followersTask = supabase.followCount(of: id, direction: "following_id")
        async let followingTask = supabase.followCount(of: id, direction: "follower_id")
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
            async let match = supabase.tasteMatch(with: id)
            async let memberWatchlistTask = supabase.watchlist(userID: id)
            async let blockedTask = supabase.blockedIDs()
            profile = try? await profileTask.asProfile
            rankings = (try? await rankingsTask) ?? []
            let rows = (try? await supabase.movies(ids: rankings.map(\.movieId))) ?? []
            for row in rows { movies[row.tmdbId] = row.asMovie }
            following = await followingState
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
        followerCount = await followersTask
        followingCount = await followingTask
        globalRank = try? await rankTask
        loaded = true
        lastLoaded = Date()
    }

    // MARK: Header (self only)

    private var header: some View {
        HStack {
            Text(profile.flatMap { $0.displayName.isEmpty ? nil : $0.displayName } ?? "Profile")
                .font(.title2.weight(.bold))
            Spacer()
            HStack(spacing: 18) {
                ShareLink(item: "Follow me on Cini — I'm @\(profile?.username ?? "") 🎬") {
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
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
        }
    }

    // MARK: Top 3 — the ranking speaks for itself

    /// Letterboxd makes people hand-pick favorites; Cini already knows.
    /// The top three ranked films, always current, on every profile.
    @ViewBuilder
    private var topThree: some View {
        let top = rankings.prefix(3).compactMap { row in
            movies[row.movieId].map { (row: row, movie: $0) }
        }
        if !top.isEmpty {
            HStack(spacing: 12) {
                Spacer(minLength: 0)
                ForEach(Array(top.enumerated()), id: \.element.row.id) { index, entry in
                    Button {
                        detailMovie = entry.movie
                    } label: {
                        PosterView(url: entry.movie.posterURL, width: 92)
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

    // MARK: Identity + stats

    private var identity: some View {
        VStack(spacing: 8) {
            AvatarView(url: profile?.avatarURL, size: 104,
                       name: profile.map { $0.displayName.isEmpty ? $0.username : $0.displayName } ?? username)
            Text("@\(profile?.username ?? username ?? "—")").font(.headline)
            Text(profile?.memberSinceText ?? "").font(.subheadline).foregroundStyle(Theme.gray)
            if let bio = profile?.bio, !bio.isEmpty {
                Text(bio)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
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
            if let matchPct, !isSelf {
                Text("+\(Int(matchPct))% Match")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.scoreGreen)
            }
        }
    }

    private var statRow: some View {
        HStack {
            if let id = resolvedID {
                NavigationLink {
                    FollowListScreen(userID: id, direction: .followers)
                } label: {
                    stat("\(followerCount)", "Followers")
                }
                .buttonStyle(.plain)
                NavigationLink {
                    FollowListScreen(userID: id, direction: .following)
                } label: {
                    stat("\(followingCount)", "Following")
                }
                .buttonStyle(.plain)
            } else {
                stat("\(followerCount)", "Followers")
                stat("\(followingCount)", "Following")
            }
            stat(globalRank.map { "#\($0)" } ?? "—", "Rank on Cini")
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
                }
                if showSuggested {
                    suggestedStrip
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
        } else if let id = resolvedID {
            HStack(spacing: 12) {
                PillButton(title: following ? "Following" : "Follow",
                           style: following ? .outlined : .filled) {
                    Task {
                        let wasFollowing = following
                        following.toggle()   // optimistic; reverted on failure
                        do {
                            if wasFollowing {
                                try await SupabaseService.shared.unfollow(id)
                            } else {
                                try await SupabaseService.shared.follow(id)
                            }
                            await load()   // visibility may have changed
                        } catch {
                            following = wasFollowing
                        }
                    }
                }
                // Their taste, on demand — asks need a follow (the RPC
                // enforces it), so the button appears once they're a friend.
                if following && !blocked {
                    PillButton(title: "Ask for a rec", systemImage: "hand.wave",
                               style: .outlined) {
                        showAskRec = true
                    }
                }
                // Moderation: report or block from any member profile.
                Menu {
                    Button(role: .destructive) {
                        Task {
                            await SupabaseService.shared.report(
                                kind: "member", subjectID: id.uuidString)
                            reported = true
                            ToastCenter.shared.show("Reported — we'll review it")
                        }
                    } label: {
                        Label(reported ? "Reported" : "Report member", systemImage: "flag")
                    }
                    .disabled(reported)
                    Button(role: .destructive) {
                        if blocked {
                            // Unblocking restores, no confirmation needed.
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
                    Image(systemName: "ellipsis")
                        .font(.title3)
                        .foregroundStyle(Theme.ink)
                        .padding(10)
                        .contentShape(Rectangle())
                }
                // Blocking is heavy — always confirm before mutual invisibility.
                .confirmationDialog("Block @\(profile?.username ?? username ?? "member")?",
                                    isPresented: $showBlockConfirm, titleVisibility: .visible) {
                    Button("Block", role: .destructive) {
                        Task {
                            do {
                                try await SupabaseService.shared.block(id)
                                ToastCenter.shared.show("Blocked — their content is hidden everywhere")
                                blocked = true
                                await load()   // their content disappears server-side
                            } catch {
                                ToastCenter.shared.saveFailed()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("You won't see each other's rankings, notes, or activity.")
                }
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
                                Text(member.displayName.isEmpty ? member.username : member.displayName)
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
                                } else {
                                    followedSuggested.insert(member.id)
                                    do { try await SupabaseService.shared.follow(member.id) }
                                    catch { followedSuggested.remove(member.id); ToastCenter.shared.saveFailed() }
                                }
                            }
                        } label: {
                            Text(followedSuggested.contains(member.id) ? "Following" : "Follow")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(followedSuggested.contains(member.id) ? Theme.marquee : .white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(followedSuggested.contains(member.id)
                                                           ? Theme.marqueeSoft : Theme.velvet))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .frame(width: 118)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(Theme.surface)
                            .overlay(RoundedRectangle(cornerRadius: 14)
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
        VStack(spacing: 0) {
            // Your own Watched / Want to Watch live in the Lists tab —
            // jump there instead of pushing a second copy of the list.
            if isSelf {
                Button {
                    tabRouter.pendingListsTab = .watched
                    tabRouter.selection = .lists
                } label: {
                    listRow(icon: "checkmark.circle", title: "Watched", count: rankings.count)
                }
                .buttonStyle(.plain)
                Divider()
                Button {
                    tabRouter.pendingListsTab = .watchlist
                    tabRouter.selection = .lists
                } label: {
                    listRow(icon: "bookmark", title: "Want to Watch", count: watchlistCount)
                }
                .buttonStyle(.plain)
            } else {
                NavigationLink {
                    RankedListScreen(title: "Watched", rankings: rankings, movies: movies,
                                     isSelf: isSelf, emptyHint: lockedHint)
                } label: {
                    listRow(icon: "checkmark.circle", title: "Watched", count: rankings.count)
                }
                .buttonStyle(.plain)
                Divider()
                NavigationLink {
                    WatchlistScreen(userID: resolvedID, isSelf: isSelf)
                } label: {
                    listRow(icon: "bookmark", title: "Want to Watch", count: watchlistCount)
                }
                .buttonStyle(.plain)
            }
            Divider()
            NavigationLink {
                CustomListsScreen(userID: resolvedID, isSelf: isSelf)
            } label: {
                listRow(icon: "list.star", title: "Lists", count: nil)
            }
            .buttonStyle(.plain)
            Divider()
            NavigationLink {
                DiaryScreen(userID: resolvedID, isSelf: isSelf)
            } label: {
                listRow(icon: "book", title: "Diary", count: nil)
            }
            .buttonStyle(.plain)
            if !isSelf {
                Divider()
                NavigationLink {
                    BothWantToWatchScreen(username: profile?.username ?? username ?? "them",
                                          rows: bothWantToWatch)
                } label: {
                    listRow(icon: "person.2", title: "You both want to watch",
                            count: bothWantToWatch.count)
                }
                .buttonStyle(.plain)
            }
            if isSelf {
                Divider()
                // One Recs surface, not two: this row jumps to the Lists
                // tab's Recs instead of duplicating the screen.
                Button {
                    tabRouter.pendingListsTab = .recs
                    tabRouter.selection = .lists
                } label: {
                    listRow(icon: "heart", title: "Recs for You", count: nil)
                }
                .buttonStyle(.plain)
            }
        }
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
            HairlineCard {
                VStack(alignment: .leading, spacing: 6) {
                    Image(systemName: "trophy").font(.title3).foregroundStyle(Theme.marquee)
                    Text("Rank on Cini").font(.subheadline).foregroundStyle(Theme.marquee)
                    Text(globalRank.map { "#\($0)" } ?? "Unranked")
                        .font(globalRank == nil ? .headline : .title2.weight(.bold))
                        .foregroundStyle(Theme.marquee)
                    if globalRank == nil && isSelf {
                        Text("Rank a movie to enter the board")
                            .font(.caption2)
                            .foregroundStyle(Theme.gray)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
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
                            Text("Rank one movie to light the flame")
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

    @ViewBuilder
    private var activityContent: some View {
        if events.isEmpty && loaded {
            Text(lockedHint ?? (isSelf ? "Rank or save a movie and it shows up here."
                                       : "No activity visible yet."))
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
        ForEach(events.prefix(12)) { event in
            let movie = event.movies?.asMovie
            HStack(spacing: 12) {
                if let movie {
                    PosterView(url: movie.posterURL, width: 36)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(activityLine(event)).font(.subheadline).lineLimit(2)
                    Text(event.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .onTapGesture { if let movie { detailMovie = movie } }
            Divider()
        }
    }

    private func activityLine(_ event: FeedEventRow) -> AttributedString {
        let who = isSelf ? "You" : "@\(profile?.username ?? username ?? "They")"
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
            Text(lockedHint ?? "Rank a few movies and the taste profile appears here.")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        } else {
            VStack(alignment: .leading, spacing: 16) {
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
            if let rank {
                Text("\(rank)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .frame(minWidth: 26, alignment: .leading)
            }
            PosterView(url: movie.posterURL, width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
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
            }
            Button {
                bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
            } label: {
                Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                    .font(.title3)
                    .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
            }
            .buttonStyle(.plain)
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
    var emptyHint: String?

    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var searchText = ""
    @State private var showSearch = false
    @State private var filters = MovieFilters()

    /// Rank numbers come from the full list, then the filters apply, so
    /// "#14" stays #14 while searching.
    private var visible: [(index: Int, row: RankingRow)] {
        let all = Array(rankings.enumerated()).map { (index: $0.offset, row: $0.element) }
        let query = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { entry in
            guard let movie = movies[entry.row.movieId] else { return true }
            guard filters.passes(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                        }
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
                    .padding(.bottom, 10)
                }
                if rankings.isEmpty {
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
        .scrollDismissesKeyboard(.immediately)
        .background(Theme.background)
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

/// A user's watchlist, pushed from the Watchlist row. Your own list reads
/// straight from the store so removing a save updates the rows live.
struct WatchlistScreen: View {
    let userID: UUID?
    let isSelf: Bool

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
            return filters.passes(movie)
        }
    }

    var body: some View {
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
        .background(Theme.background)
        .navigationTitle("Want to Watch (\(entries.count))")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .fullScreenCover(item: $logMovie) { movie in
            LogFlowView(movie: movie)
        }
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

    @Environment(RankingStore.self) private var store
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if rows.isEmpty {
                    Text("No overlap yet — save a few of @\(username)'s Want to Watch picks and they show up here.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 32)
                } else {
                    Text("On both of your Want to Watch lists — perfect for a watch party.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .padding(.bottom, 8)
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
