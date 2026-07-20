import SwiftUI
import UserNotifications

struct FeedView: View {
    @Environment(AppSession.self) private var session
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.scenePhase) private var scenePhase
    /// Throttle foreground refreshes so a quick app-switch doesn't re-fetch.
    @State private var lastFeedLoad = Date.distantPast

    @State private var events: [FeedEventRow] = []
    @State private var likedEventIDs: Set<UUID> = []
    @State private var feedLoaded = false
    @State private var unreadCount = 0
    @State private var detailMovie: Movie?
    /// Set just before `detailMovie` when the open came from a "watch tonight"
    /// swipe, so the detail page auto-presents Where to Watch. Cleared on a plain
    /// tap-open so it never lingers into the next navigation.
    @State private var detailAutoWatch = false
    @State private var logMovie: Movie?
    /// The Tonight's Pick whose streaming badge was tapped → Where-to-Watch.
    @State private var watchSheetItem: TonightCardItem?
    @State private var memberTarget: MemberRef?
    @State private var likersTarget: LikersTarget?
    @State private var commentsLink: CommentsLink?
    /// Live comment counts reported back from open threads, keyed by event id.
    @State private var commentCountOverrides: [UUID: Int] = [:]
    /// How many people have each title on their Want to Watch, keyed by tmdbID
    /// — Beli-style social proof shown over the bookmark on each card.
    @State private var savedCounts: [Int: Int] = [:]
    @State private var showImport = false
    @State private var showMenuImport = false
    @State private var showSettings = false
    @State private var showInviteSheet = false
    @State private var showLogoutConfirm = false
    @State private var showAskRecs = false
    @State private var showRespondRecs = false
    @State private var pendingAsks: [RecRequestRow] = []
    /// Observed so "Ask your friends for recs" can hide until you have friends.
    @State private var friendsCache = FriendsCache.shared
    @State private var tonightCards: [TonightCardItem] = []
    /// Whether a Tonight's Pick load has completed at least once this session, so
    /// the zero-state only appears after a real attempt — not as a flash before
    /// the first load resolves.
    @State private var tonightLoaded = false
    /// Set once a "Show more" pull turns up nothing — there's no more to surface
    /// from Want to Watch right now, so the zero-state points to Recs instead.
    @State private var tonightExhausted = false
    /// Whether the deck has shown at least one card this session — distinguishes
    /// "you swiped through them" from "nothing was ever surfaceable tonight."
    @State private var tonightEverHadCards = false
    /// Whether the last build left eligible picks unshown beyond the 3-card deck.
    /// Only when this is true is "Show more" offered — otherwise tapping it would
    /// just rebuild to an empty deck (everything shown today is hard-skipped),
    /// which read as a glitch. False = go straight to the cleared zero-state.
    @State private var tonightHasMore = false
    /// Guards against overlapping loads (several `.task`/refresh triggers fire it).
    @State private var tonightLoading = false
    // Picks dismissed today, persisted so a swiped/✕'d pick stays gone.
    @AppStorage("tonight.dismissed.date") private var tonightDismissedDate = ""
    @AppStorage("tonight.dismissed.ids") private var tonightDismissedIDs = ""
    // Once the whole deck is cleared (dismissed or ranked through), suppress new
    // Tonight's Picks for 24h and show the "find more in Recs" empty state.
    @AppStorage("tonight.suppressedUntil") private var tonightSuppressedUntil = 0.0
    /// Accounts already shown the one-time, deferred notifications re-ask.
    @AppStorage("cini.notifReaskedUserIDs") private var notifReaskedRaw = ""
    @State private var showNotifReask = false
    @State private var showStreakInfo = false
    // 14-day rolling log: "movieID:dayNum,…" — prevents the same title showing
    // twice in a day; stale entries are pruned on each load.
    @AppStorage("tonight.shownLog") private var tonightShownLog = ""
    @State private var watchPlanContext: WatchPlanContext?
    @State private var friendsWatchingRows: [FriendWatchingRow] = []
    @State private var watchingStory: FriendWatchingRow?
    @AppStorage("feed.hideWatchingStories") private var hideWatchingStories = false
    /// The founder's one-time "invite one friend" note — surfaced on the user's
    /// second app open (not their first, so it isn't the very first thing they
    /// see), and never again once dismissed or acted on. Both keys are
    /// PER-ACCOUNT (like `onboardedUserIDs`): on a shared device, one user's
    /// dismissal must not hide the note from the next, and a fresh signup must
    /// not inherit the device's launch count and get asked on first open.
    /// Legacy device-wide flag, still honored for users who dismissed pre-update.
    @AppStorage("founder.shareAsked") private var founderShareAsked = false
    /// Comma-joined user ids who saw the note.
    @AppStorage("founder.shareAskedUsers") private var founderShareAskedRaw = ""
    /// Per-account app-open counts, encoded "uid:count,uid:count".
    @AppStorage("app.launchCountsByUser") private var launchCountsRaw = ""
    /// Per-launch guard so the counter increments once, not on every feed appear.
    @State private var countedThisLaunch = false
    @State private var showFounderShare = false
    /// Trending titles, shown as a "Popular on Cini" shelf so a feed with few
    /// friends still has something fresh to rank/bookmark (new-user retention).
    @State private var popularMovies: [Movie] = []
    /// "Watching at <school>" shelf: classmates' recent ranks + how many ranked each.
    @State private var schoolMovies: [Movie] = []
    @State private var schoolRankers: [Int: Int] = [:]

    var body: some View {
        NavigationStack {
            // Header, search, and the pill row stay frozen; only the
            // feed itself scrolls underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 14) {
                    header
                    feedSearchBar
                }
                .screenHPadding()
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollViewReader { proxy in
                    ScrollView {
                        yourFeed
                            .screenHPadding()
                            .id("feedTop")
                    }
                    .refreshable { await loadFeed(); await loadTonightStack(force: true) }
                    // Tapping the Feed tab while on Feed jumps back to the top.
                    .onChange(of: tabRouter.retap[.feed]) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("feedTop", anchor: .top) }
                    }
                }
            }
            .nativeContentWidth()
            .background(Theme.background)
            .task { await loadFeed() }   // loadFeed also refreshes friendsWatchingRows
            .task { friendsCache.refreshIfStale() }   // for the ask-friends gate
            // Coming back to the app after a while should show a fresh feed,
            // not yesterday's — throttled so a quick switch-away doesn't refetch.
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                // The app-icon badge clears on every foreground. (The old
                // AppDelegate applicationDidBecomeActive hook is dead code
                // under the SwiftUI scene lifecycle — this is the real path.)
                PushManager.clearBadge()
                guard Date().timeIntervalSince(lastFeedLoad) > 45 else { return }
                Task { await loadFeed() }
            }
            .task(id: store.isLoaded) { await loadTonightStack() }
            // Also re-check when the rank count changes — the unlock is taste-
            // based, so crossing the threshold (e.g. ranking during onboarding)
            // should reveal Tonight's Pick without waiting for a relaunch.
            .task(id: store.watchedCount) { await loadTonightStack() }
            // A new bookmark feeds Tonight's Picks. loadTonightStack is lazy
            // (rebuilds only when the deck is empty unless forced) and bails on a
            // cleared/suppressed deck — so saving a title while a zero-state shows
            // surfaces a fresh pick, without churning an already-built deck or
            // overriding an "I'm done tonight" clear.
            .task(id: store.watchlistCount) { await loadTonightStack() }
            .task(id: store.isLoaded) { await loadPopular() }
            .task(id: session.profile?.school) { await loadSchoolTrending() }
            // The notifications re-ask needs the profile (memberSince), which
            // loads slightly after the store — re-run once it's known. (The
            // Tonight's-Pick gate is taste-based now and rides store.isLoaded.)
            .task(id: session.profile?.id) {
                await loadTonightStack()
                await maybeAskNotifications()
            }
            // Tapped push notifications land here (cold launch included) —
            // consume on appear AND on change, since the tab stays alive.
            .onAppear { consumePush() }
            .onChange(of: tabRouter.pendingPushMovieID) { _, _ in consumePush() }
            .onChange(of: tabRouter.pendingPushMember) { _, _ in consumePush() }
            .onChange(of: tabRouter.pendingPushCommentEvent) { _, _ in consumePush() }
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
                    },
                    onOpenProfile: { r in
                        // Sheet dismisses itself first; push the profile after.
                        Task {
                            try? await Task.sleep(for: .milliseconds(350))
                            memberTarget = MemberRef(id: r.userId, username: r.username)
                        }
                    }
                )
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie, autoShowWhereToWatch: detailAutoWatch)
            }
            // The auto-open-Where-to-Watch intent belongs to one swipe-right open
            // only. Clear it when the detail closes so a later tap (a feed row,
            // a poster) doesn't inherit it and pop the sheet unexpectedly.
            .onChange(of: detailMovie) { _, new in
                if new == nil { detailAutoWatch = false }
            }
            .navigationDestination(item: $memberTarget) { member in
                MemberProfileView(userID: member.id, username: member.username)
            }
            .sheet(item: $likersTarget) { target in
                LikersSheet(eventID: target.id, onOpenMember: { memberTarget = $0 })
            }
            .navigationDestination(item: $commentsLink) { link in
                CommentsSheet(
                    eventID: link.id,
                    context: link.context,
                    onOpenMember: { memberTarget = $0 },
                    onCommentCountChange: { commentCountOverrides[link.id] = $0 }
                )
            }
            .fullScreenCover(item: $logMovie, onDismiss: { clearRankedTonightCards() }) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(item: $watchSheetItem) { item in
                WhereToWatchSheet(movie: item.movie, providers: item.providers)
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showMenuImport) {
                LetterboxdImportView()
            }
            // Presented from the first-run empty-state card. The sheet must
            // live up here at stack level: the card leaves the hierarchy as
            // soon as the first imported title lands in the store, and a
            // sheet attached to it would be torn down mid-import.
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            // The deferred notifications ask: shown once, a day+ after signup,
            // and only after they've actually ranked something (see
            // maybeAskNotifications) — never on the day they sign up.
            .fullScreenCover(isPresented: $showNotifReask) {
                NotificationPrimer(
                    onTurnOn: { Task { _ = await PushManager.request(); showNotifReask = false } },
                    onSkip: { showNotifReask = false }
                )
                .background(Theme.background.ignoresSafeArea())
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
            .sheet(isPresented: $showStreakInfo) {
                StreakInfoSheet(weeks: session.profile?.streakWeeks ?? 0,
                                atRisk: session.profile?.streakAtRisk ?? false) {
                    showStreakInfo = false
                    tabRouter.selection = .search
                }
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: $showRespondRecs, onDismiss: {
                Task { pendingAsks = (try? await SupabaseService.shared.incomingRecRequests()) ?? [] }
            }) {
                RespondRecSheet()
            }
            // The founder's one-time "invite one friend" note — a dismissible
            // popup over the feed whose CTA opens the contacts invite sheet.
            .overlay {
                if showFounderShare {
                    FounderShareCard(
                        onShare: {
                            markFounderAsked()
                            withAnimation(.snappy) { showFounderShare = false }
                            // Let the overlay clear before presenting the sheet —
                            // two presentations in one runloop can swallow the second.
                            Task {
                                try? await Task.sleep(for: .milliseconds(280))
                                showInviteSheet = true
                            }
                        },
                        onDismiss: {
                            markFounderAsked()
                            withAnimation(.snappy) { showFounderShare = false }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .zIndex(60)
                }
            }
            .animation(.snappy, value: showFounderShare)
            .onAppear { countLaunchAndMaybeAskFounder() }
        }
    }

    /// Count this app load once for the signed-in account, then surface the
    /// founder's "invite one friend" note on that account's second open onward —
    /// never on their first, and never again once dismissed or acted on.
    private func countLaunchAndMaybeAskFounder() {
        guard let uid = SupabaseService.shared.currentUserID?.uuidString else { return }
        var counts: [String: Int] = [:]
        for pair in launchCountsRaw.split(separator: ",") {
            let parts = pair.split(separator: ":")
            if parts.count == 2, let n = Int(parts[1]) { counts[String(parts[0])] = n }
        }
        if !countedThisLaunch {
            countedThisLaunch = true
            counts[uid, default: 0] += 1
            launchCountsRaw = counts.map { "\($0.key):\($0.value)" }.joined(separator: ",")
        }
        // Yield to higher-priority launch prompts (the notifications re-ask, the
        // one-time product tour) so two asks never compete. If blocked this
        // launch, the note simply waits for the next clean one (it's persisted).
        let asked = founderShareAskedRaw.split(separator: ",").map(String.init)
        guard !founderShareAsked, !asked.contains(uid), !showFounderShare,
              counts[uid, default: 0] >= 2,
              !showNotifReask, !tabRouter.tourActive else { return }
        withAnimation(.snappy) { showFounderShare = true }
    }

    /// The note was seen to completion (shared or dismissed) — never again
    /// for this account.
    private func markFounderAsked() {
        guard let uid = SupabaseService.shared.currentUserID?.uuidString else { return }
        if !founderShareAskedRaw.split(separator: ",").map(String.init).contains(uid) {
            founderShareAskedRaw += founderShareAskedRaw.isEmpty ? uid : ",\(uid)"
        }
    }

    // MARK: Header: serif wordmark + calendar / bell / hamburger

    /// A frozen, tappable search bar styled like the Search tab's field —
    /// tapping it jumps to the Search tab (which auto-focuses the real field).
    private var feedSearchBar: some View {
        Button {
            tabRouter.openMembersSearch = false
            tabRouter.selection = .search
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                Text("Search movies, shows, members")
                    .foregroundStyle(Theme.gray)
                Spacer()
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
        .buttonStyle(.plain)
    }

    private var header: some View {
        HStack {
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.marquee)
            if let weeks = session.profile?.streakWeeks, weeks > 0 {
                streakPill(weeks, atRisk: session.profile?.streakAtRisk ?? false)
            }
            Spacer()
            HStack(spacing: 2) {
                // Search now lives in the dedicated bar below the header.
                NavigationLink {
                    TheaterCalendarView()
                } label: {
                    Image(systemName: "calendar")
                        .frame(width: 44, height: 44)
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
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Notifications")
                // Opening the list marks everything read server-side, but the
                // feed stays mounted (a push) so loadFeed()'s .task never
                // re-fires — clear the dot optimistically on tap so it can't
                // linger until a manual refresh.
                .simultaneousGesture(TapGesture().onEnded { unreadCount = 0 })
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
                        .frame(width: 44, height: 44)
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

    /// Go follow more people — the in-app, highest-yield way to fuel the feed.
    private func openFindFriends() {
        tabRouter.openMembersSearch = true
        tabRouter.selection = .search
    }

    /// "Bring friends in" card, shown until you follow enough people for a lively
    /// feed (`friendsFeedBar`). The feed — friends' rankings and what they're
    /// watching — is the payoff worth referring for, so we keep this in front of
    /// thin-graph users. Two treatments share the same two actions (find friends
    /// in-app; invite off-app):
    ///   • `compact: false` — a big payoff card for a user who follows no one.
    ///   • `compact: true`  — a slim "follow a few more" card once they've got
    ///     at least one friend, so it doesn't dominate an active feed.
    @ViewBuilder private func friendsFeedCTA(compact: Bool) -> some View {
        if compact {
            let friends = friendsCache.following.count
            HairlineCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: "person.2.fill")
                            .font(.title3)
                            .foregroundStyle(Theme.marquee)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Cini's better with more friends")
                                .font(.subheadline.weight(.bold)).foregroundStyle(Theme.ink)
                            Text(friends == 0
                                 ? "Invite a few to fill out your feed."
                                 : "You follow \(friends) \(friends == 1 ? "friend" : "friends") — invite a few more to fill out your feed.")
                                .font(.caption).foregroundStyle(Theme.gray)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    // Soft progress toward a lively feed — visible momentum, not a
                    // hard quota (the copy never says "get to N"). Caps the fill at
                    // the bar so it reads as "almost there," then the card retires.
                    ProgressView(value: Double(min(friends, Self.friendsFeedBar)),
                                 total: Double(Self.friendsFeedBar))
                        .tint(Theme.marquee)
                    // Invite leads: at launch almost no one's friends are on Cini
                    // yet, so bringing people in is the growth lever; "find friends"
                    // (already-on-Cini) is the secondary path.
                    HStack(spacing: 14) {
                        PillButton(title: "Invite friends", systemImage: "square.and.arrow.up") {
                            Haptics.tap()
                            showInviteSheet = true
                        }
                        Button {
                            openFindFriends()
                        } label: {
                            Text("Find friends")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.marquee)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        } else {
            HairlineCard {
                VStack(spacing: 14) {
                    Image(systemName: "person.2.fill")
                        .font(.title)
                        .foregroundStyle(Theme.marquee)
                    Text("See what your friends are watching")
                        .font(Theme.serif(24))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(Theme.ink)
                    Text("Invite a few friends — your feed comes alive.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)

                    PillButton(title: "Invite friends", systemImage: "square.and.arrow.up") {
                        Haptics.tap()
                        showInviteSheet = true
                    }
                    Button {
                        openFindFriends()
                    } label: {
                        Text("Find friends on Cini")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.marquee)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }

    /// "Popular on Cini" — a horizontal poster shelf of trending titles with
    /// the standard (+)/bookmark quick actions, so even a friendless feed has
    /// something to do. Reuses ArtworkQuickActions so the placements can't drift.
    private var popularOnCiniShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "flame.fill").foregroundStyle(Theme.marquee)
                Text("Popular on Cini")
                    .font(.headline).foregroundStyle(Theme.ink)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(popularMovies.prefix(12)) { movie in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: movie.posterURL, width: 116)
                                .overlay(alignment: .bottomTrailing) {
                                    ArtworkQuickActions(movie: movie, onLog: { logMovie = $0 })
                                        .font(.body)
                                        .padding(6)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.cache(movie)
                                    detailMovie = movie
                                }
                            Text(movie.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .frame(width: 116, alignment: .leading)
                        }
                    }
                }
                // Edge-to-edge scroll like the watching stories.
                .padding(.horizontal, Theme.screenH)
            }
            .padding(.horizontal, -Theme.screenH)
        }
    }

    /// Always-visible streak badge — the habit anchor. Glanceable count of
    /// consecutive ranking weeks; a soft gold chip normally, flipping to a
    /// solid gold fill when the streak's about to lapse. Tapping explains how
    /// streaks work (and how to keep this one alive).
    private func streakPill(_ weeks: Int, atRisk: Bool) -> some View {
        Button {
            Haptics.tap()
            showStreakInfo = true
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "flame.fill")
                    .font(.caption2)
                Text("\(weeks)")
                    .font(.caption.weight(.bold))
                    .monospacedDigit()
            }
            .foregroundStyle(atRisk ? Theme.background : Theme.gold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(atRisk ? Theme.gold : Theme.gold.opacity(0.14))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(weeks)-week ranking streak\(atRisk ? ", ending soon" : "")")
    }

    /// "What should I watch?" aimed at your actual friends: pick people,
    /// optionally narrow by type/genre, and their answers land in
    /// Friend Recs.
    private var askForRecsRow: some View {
        Button {
            showAskRecs = true
        } label: {
            HStack(spacing: 10) {
                AvatarView(url: session.profile?.avatarURL, size: 26,
                           name: preferredName(session.profile?.displayName,
                                               session.profile?.username))
                Text("Ask your friends for recs")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .background(Capsule().fill(Theme.fill))
            .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
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
                Text("It's been on your list a while. Watch it tonight?")
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
                    .frame(width: 44, height: 44)
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

    // MARK: Feed

    private var yourFeed: some View {
        // Lazy so an unbounded feed only builds the cards on screen — keeps
        // scrolling smooth as the feed grows.
        LazyVStack(alignment: .leading, spacing: 16) {
            // What friends are binging right now — story circles at the top.
            if !hideWatchingStories {
                FriendsWatchingShelf(rows: friendsWatchingRows, onTap: { watchingStory = $0 })
                    .padding(.top, 6)
                    // Break out of the feed's inset so the stories scroll
                    // edge-to-edge (Instagram-style) instead of clipping at the margin.
                    .padding(.horizontal, -Theme.screenH)
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
                // Swipe-hint line, mirroring the Recs deck's instruction note so
                // the gestures are discoverable (left = not tonight, right = watch).
                Label("Swipe right to watch tonight · left for not tonight", systemImage: "hand.tap")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                TonightStack(
                    items: tonightCards,
                    onOpen: { detailAutoWatch = false; detailMovie = $0 },
                    onWatchTonight: { detailAutoWatch = true; detailMovie = $0 },
                    onRank: { logMovie = $0 },
                    onDismiss: { dismissTonight($0) },
                    onShowProviders: { watchSheetItem = $0 }
                )
                .padding(.top, 2)
                // The deck reserves a fixed height, but a dragged/rotated card
                // (and the card flying off on dismiss) overflows that frame. Keep
                // it drawn above the rows below — otherwise "Ask friends for a
                // rec" paints over it, since VStack draws later siblings on top.
                .zIndex(1)
            } else if tonightUnlocked, tonightLoaded {
                // Unlocked, finished loading, but no card to show — always land on
                // a zero-state (the deck should never just silently vanish). Pick
                // the HONEST one based on why it's empty:
                if store.watchlistCount == 0 {
                    // Nothing saved at all. (Label the closure: a bare trailing
                    // closure would bind to onShowMore — the LAST param — leaving
                    // the "Find something in Recs" button calling an empty onSwipe.)
                    TonightEmptyState(.emptyWatchlist, onSwipe: { tabRouter.selection = .swipe })
                        .padding(.top, 2)
                } else if !tonightEverHadCards && dismissedTonightToday().isEmpty {
                    // Has saved titles but none surfaced AND none were dismissed
                    // today — none are streamable / all ranked. Don't claim they
                    // swiped through picks they never saw. (dismissedTonightToday is
                    // persisted, so it still proves "had cards" after a relaunch,
                    // when the in-session tonightEverHadCards flag has reset.)
                    TonightEmptyState(.nothingTonight, onSwipe: { tabRouter.selection = .swipe })
                        .padding(.top, 2)
                } else if tonightExhausted || !tonightHasMore {
                    // Either explicitly exhausted, or the deck already showed every
                    // eligible pick (nothing waiting). Go straight to the cleared
                    // zero-state — don't offer a "Show more" that just rebuilds to
                    // empty and flashes back to this same state.
                    TonightEmptyState(.cleared, onSwipe: { tabRouter.selection = .swipe })
                        .padding(.top, 2)
                } else {
                    // Swiped through the shown deck, but more eligible picks remain.
                    TonightEmptyState(.showMore,
                                      onSwipe: { tabRouter.selection = .swipe },
                                      onShowMore: { Task { await showMoreTonight() } })
                        .padding(.top, 2)
                }
            }

            // Only when there's someone to ask — a friendless new user shouldn't
            // see "Ask your friends for recs" (a dead-end prompt).
            if !friendsCache.following.isEmpty {
                askForRecsRow
            }

            // Bring-friends-in card, shown until the friend graph is big enough
            // for a lively feed (gated on friend COUNT — see friendsNudgeMode).
            // Placed ABOVE the Popular shelf so the referral ask is the headline,
            // not a footnote. `.full` is the big payoff card for a friendless
            // user; `.compact` is a slim "follow a few more" card once they've
            // got at least one friend, so it doesn't dominate an active feed.
            if let mode = friendsNudgeMode {
                friendsFeedCTA(compact: mode == .compact)
                    .padding(.top, mode == .compact ? 4 : 0)
            }

            // What your campus is watching — classmates' recent ranks.
            if !schoolMovies.isEmpty {
                schoolShelf
                    .padding(.top, 4)
            }

            // Popular on Cini — keeps a thin/new feed alive with fresh titles
            // to rank or bookmark. Shown while friend activity is sparse (the
            // lone-user case); fades out naturally once the feed fills in.
            if feedLoaded, events.count < 3, !popularMovies.isEmpty {
                popularOnCiniShelf
                    .padding(.top, 4)
            }

            if events.isEmpty {
                if feedLoaded {
                    // The friends nudge above already covers the thin-graph cases.
                    // Here we only show the first-run "rank your first movie"
                    // state when no friends card is being shown (brand-new user,
                    // or a user with enough friends but a momentarily quiet feed).
                    if friendsNudgeMode == nil {
                        emptyState
                    }
                } else {
                    FeedSkeleton()
                        .padding(.top, 4)
                }
            }

            // Friends' activity. (Tonight's Pick at the top is now the single
            // first-party recommendation surface — the old interspersed
            // "Promoted release" card was redundant and removed.)
            ForEach(events) { event in
                FeedCard(
                    event: event,
                    initiallyLiked: likedEventIDs.contains(event.id),
                    onOpenMovie: { detailMovie = $0 },
                    onQuickAdd: { logMovie = $0 },
                    onOpenMember: { memberTarget = $0 },
                    onOpenComments: { ev, ctx in commentsLink = CommentsLink(id: ev.id, context: ctx) },
                    commentCountOverride: commentCountOverrides[event.id],
                    savedCount: event.movies.flatMap { savedCounts[$0.tmdbId] },
                    onShowLikers: { likersTarget = LikersTarget(id: $0) }
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

    /// Load trending titles for the "Popular on Cini" shelf, dropping anything
    /// already ranked so it only ever surfaces fresh things to act on.
    private func loadPopular() async {
        guard popularMovies.isEmpty else { return }
        guard let trending = try? await TMDBService.shared.trending() else { return }
        popularMovies = trending.filter { $0.posterPath != nil && !store.isWatched($0.tmdbID) }
    }

    /// Load what classmates (same school) are ranking, for the campus shelf.
    private func loadSchoolTrending() async {
        guard session.profile?.school != nil else { schoolMovies = []; return }
        let rows = await SupabaseService.shared.schoolTrending()
        guard !rows.isEmpty else { schoolMovies = []; return }
        let fetched = (try? await SupabaseService.shared.movies(ids: rows.map(\.movieId))) ?? []
        var byID: [Int: Movie] = [:]
        for row in fetched { byID[row.tmdbId] = row.asMovie }
        schoolRankers = Dictionary(rows.map { ($0.movieId, $0.rankers) }, uniquingKeysWith: { a, _ in a })
        // Keep the RPC's order (most classmates first) and only titles with art.
        schoolMovies = rows.compactMap { byID[$0.movieId] ?? store.movie($0.movieId) }
            .filter { $0.posterPath != nil }
    }

    /// "Watching at <school>" — a campus poster shelf with classmate social proof.
    private var schoolShelf: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "graduationcap.fill").foregroundStyle(Theme.marquee)
                Text("Watching at \(session.profile?.school ?? "your school")")
                    .font(.headline).foregroundStyle(Theme.ink).lineLimit(1)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(schoolMovies.prefix(12)) { movie in
                        VStack(alignment: .leading, spacing: 6) {
                            PosterView(url: movie.posterURL, width: 116)
                                .overlay(alignment: .bottomTrailing) {
                                    ArtworkQuickActions(movie: movie, onLog: { logMovie = $0 })
                                        .font(.body)
                                        .padding(6)
                                }
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    store.cache(movie)
                                    detailMovie = movie
                                }
                            Text(movie.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                                .frame(width: 116, alignment: .leading)
                            if let n = schoolRankers[movie.tmdbID], n > 0 {
                                Text(n == 1 ? "1 classmate ranked it" : "\(n) classmates ranked it")
                                    .font(.caption2).foregroundStyle(Theme.gray)
                                    .frame(width: 116, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.screenH)
            }
            .padding(.horizontal, -Theme.screenH)
        }
    }

    private func consumePush() {
        if let eventID = tabRouter.pendingPushCommentEvent {
            tabRouter.pendingPushCommentEvent = nil
            commentsLink = CommentsLink(id: eventID)
        }
        if let movieID = tabRouter.pendingPushMovieID {
            tabRouter.pendingPushMovieID = nil
            Task {
                // The tap on a push must never be silently swallowed: retry
                // once, fall back to any cached copy, and if it still can't
                // open, SAY so instead of landing on a blank feed.
                var movie = try? await TMDBService.shared.details(for: movieID)
                if movie == nil { movie = try? await TMDBService.shared.details(for: movieID) }
                if movie == nil {
                    movie = store.movie(movieID)
                        ?? (try? await SupabaseService.shared.movies(ids: [movieID]))?.first?.asMovie
                }
                if let movie {
                    store.cache(movie)
                    detailMovie = movie
                } else {
                    ToastCenter.shared.show("Couldn't open that — check your connection.")
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

    /// Load several Tonight's Pick candidates and keep up to three that are
    /// actually streamable (with the service to show on the card). Skips picks
    /// already dismissed today.
    /// True while Tonight's Picks are suppressed (the user cleared the deck
    /// within the last 24h) — drives the deep-link empty state.
    private var tonightCleared: Bool {
        Date().timeIntervalSince1970 < tonightSuppressedUntil
    }

    /// The app-wide "this user is engaged" bar: how many ranked titles before we
    /// surface engagement asks (the daily pick, the invite nudge, the unlock
    /// card). Low enough that a user who ranks during onboarding clears it the
    /// same day, high enough that we never pile asks onto a near-empty account.
    private static let engagedRankBar = 5

    /// Below this many followed accounts, the feed is too thin to feel alive, so
    /// we keep a "bring friends in" card in front of the user. (A user who only
    /// follows the founder still has a one-person graph even if that account
    /// posts a lot — so this gates on friend COUNT, not feed volume.)
    private static let friendsFeedBar = 5

    /// Which "bring friends in" card to show, if any. Gated on how many people
    /// you follow, not how full the feed looks.
    private enum FriendsNudge { case full, compact }
    private var friendsNudgeMode: FriendsNudge? {
        guard feedLoaded else { return nil }
        let friends = friendsCache.following.count
        guard friends < Self.friendsFeedBar else { return nil }
        if friends == 0 {
            // The feed is built from people you follow, so a non-empty feed with
            // a zero friend count just means the friends cache hasn't loaded yet
            // — fall back to the slim card instead of flashing the big "no
            // friends" card over real activity.
            if !events.isEmpty { return .compact }
            // Truly friendless + empty feed: only an already-active user gets the
            // big payoff card. A brand-new user with nothing ranked sees the
            // first-run "rank your first movie" state instead.
            return store.watchedCount > 0 ? .full : nil
        }
        return .compact
    }

    /// Tonight's Picks unlock on taste signal, not a fixed wait: once there are
    /// a few ranked titles the daily "watch this tonight" hook can be personal,
    /// so a motivated new user gets it on day one instead of after five days.
    private var tonightUnlocked: Bool {
        store.watchedCount >= Self.engagedRankBar
    }

    /// The second, well-timed notifications ask. Onboarding no longer nags on
    /// day one; instead we wait until the habit has a foothold — at least a day
    /// after signup AND once they've ranked something — then ask exactly once.
    private func maybeAskNotifications() async {
        guard let uid = SupabaseService.shared.currentUserID?.uuidString,
              let since = session.profile?.memberSince,
              Date().timeIntervalSince(since) >= 24 * 60 * 60,   // ≥1 day after signup
              store.watchedCount >= 1,                            // has rated something
              !showFounderShare,   // founder note already up — one ask at a time
              !notifReaskedRaw.split(separator: ",").map(String.init).contains(uid)
        else { return }
        // Already on? Nothing to ask. (Covers .authorized / .provisional.)
        guard await PushManager.isAuthorized() == false else { return }
        // Mark first so it's exactly once, whatever they choose.
        notifReaskedRaw += notifReaskedRaw.isEmpty ? uid : ",\(uid)"
        showNotifReask = true
    }

    /// The service to show on a Tonight's Pick card: one the user actually
    /// subscribes to when possible (Settings → Viewing preferences),
    /// otherwise the first one TMDB lists.
    private func tonightProvider(_ providers: WatchProviders) -> WatchProviders.Provider? {
        guard let flatrate = providers.flatrate, !flatrate.isEmpty else { return nil }
        let mine = PrefsCache.shared.services
        if !mine.isEmpty, let match = flatrate.first(where: { provider in
            MovieFilters.canonicalProvider(provider.providerName).map(mine.contains) ?? false
        }) { return match }
        return flatrate.first
    }

    private func loadTonightStack(force: Bool = false) async {
        // One load at a time — several triggers (store load, watched-count change,
        // pull-to-refresh, Show more) can fire this; overlapping runs race at the
        // awaits and flash. A second caller just bails.
        guard !tonightLoading else { return }
        tonightLoading = true
        defer { tonightLoading = false }
        // Held back until there's enough taste signal (see tonightUnlocked) —
        // no Tonight's Pick section until a few titles are ranked.
        guard tonightUnlocked else { tonightCards = []; tonightLoaded = true; return }
        // Cleared the deck in the last 24h? Stay empty (the empty state shows),
        // even on a manual refresh — no new picks until the window passes.
        if tonightCleared { tonightCards = []; tonightLoaded = true; return }
        // Lazy on the .task path; a manual pull-to-refresh forces a rebuild.
        guard force || tonightCards.isEmpty else { tonightLoaded = true; return }
        let dismissed = dismissedTonightToday()
        let shownMap = tonightShownMap()
        let today = todayDayNum()
        var cards: [TonightCardItem] = []
        // Recomputed below: true only if eligible picks remain past the 3-deck cap.
        tonightHasMore = false

        // 1) Continue watching — shows you're mid-binge on lead the deck, since
        // "pick up where you left off" is the strongest watch-tonight signal.
        let inProgress = (try? await SupabaseService.shared.continueWatchingPicks()) ?? []
        if !inProgress.isEmpty {
            let rows = (try? await SupabaseService.shared.movies(ids: inProgress.map(\.showId))) ?? []
            var byID: [Int: Movie] = [:]
            for row in rows { byID[row.tmdbId] = row.asMovie }
            for show in inProgress {
                if cards.count >= 3 { break }
                if dismissed.contains(show.showId) { continue }
                if store.isWatched(show.showId) { continue }
                guard let movie = byID[show.showId] ?? store.movie(show.showId),
                      movie.posterPath != nil else { continue }
                guard let providers = try? await TMDBService.shared.watchProviders(for: show.showId),
                      let provider = tonightProvider(providers) else { continue }
                store.cache(movie)
                let ep = episodeLabel(season: show.season, episode: show.episode)
                cards.append(TonightCardItem(movie: movie,
                                             reason: ep.map { "Pick up where you left off · \($0)" }
                                                       ?? "Pick up where you left off",
                                             service: provider.providerName,
                                             serviceLogo: provider.logoURL,
                                             providers: providers,
                                             continueWatching: true))
            }
        }

        // 2) Want to Watch fills the rest of the (max 3) stack, with recency
        // filtering: same-day picks are hard-skipped (prefer nothing over repeats),
        // picks shown 1–3 days ago are used only as fallback. We always evaluate
        // eligibility (even if continue-watching already filled the deck) so the
        // "more waiting?" signal is correct.
        if let picks = try? await SupabaseService.shared.tonightPicks(limit: 15), !picks.isEmpty {
            // Partition the eligible pool first — cheap, no movie rows needed yet.
            var primary: [TonightPickRow] = []
            var deferred: [TonightPickRow] = []
            for pick in picks {
                if dismissed.contains(pick.movieId) { continue }
                if cards.contains(where: { $0.id == pick.movieId }) { continue }
                if store.isWatched(pick.movieId) { continue }
                let lastDay = shownMap[pick.movieId]
                if lastDay == today { continue }  // shown today → hard skip
                if let d = lastDay, today - d <= 3 {
                    deferred.append(pick)
                } else {
                    primary.append(pick)
                }
            }
            let pool = primary + deferred
            if cards.count >= 3 {
                // Deck already full (continue-watching) — note whether Want-to-Watch
                // picks are still waiting, so "Show more" can surface them next.
                tonightHasMore = !pool.isEmpty
            } else if !pool.isEmpty {
                let rows = (try? await SupabaseService.shared.movies(ids: pool.map(\.movieId))) ?? []
                var byID: [Int: Movie] = [:]
                for row in rows { byID[row.tmdbId] = row.asMovie }
                for pick in pool {
                    if cards.count >= 3 {
                        // Deck filled but eligible picks remain → offer "Show more."
                        // (Without this it'd be offered even when nothing's left,
                        // then flash to "cleared" — the reported glitch.)
                        tonightHasMore = true
                        break
                    }
                    // Defensive de-dupe: never add the same title twice (e.g. a
                    // continue-watching card above, or a repeated id from the RPC).
                    if cards.contains(where: { $0.id == pick.movieId }) { continue }
                    guard let movie = byID[pick.movieId] ?? store.movie(pick.movieId),
                          movie.posterPath != nil else { continue }
                    guard let providers = try? await TMDBService.shared.watchProviders(for: pick.movieId),
                          let provider = tonightProvider(providers) else { continue }
                    store.cache(movie)
                    cards.append(TonightCardItem(movie: movie,
                                                 reason: Self.tonightReason(for: pick),
                                                 service: provider.providerName,
                                                 serviceLogo: provider.logoURL,
                                                 providers: providers))
                }
            }
        }

        // Record which movies were shown so they're skipped on later reloads today.
        recordTonightShown(cards.map { $0.movie.tmdbID })
        tonightCards = cards
        tonightLoaded = true
        // Got cards → we're not exhausted (e.g. a new day, or a pull-to-refresh),
        // and we've now shown at least one card this session.
        if !cards.isEmpty { tonightExhausted = false; tonightEverHadCards = true }
    }

    /// "Show more" on the cleared deck: lift today's 24h hold and rebuild from the
    /// next un-dismissed Want-to-Watch titles. If nothing's left, mark exhausted
    /// so the slot points to Recs instead of offering "Show more" again.
    private func showMoreTonight() async {
        Haptics.tap()
        tonightSuppressedUntil = 0
        await loadTonightStack(force: true)
        if tonightCards.isEmpty { tonightExhausted = true }
    }

    private func todayKey() -> String { DateFormatter.localDay.string(from: Date()) }

    /// LOCAL-calendar day ordinal, used for the Tonight's Pick 14-day recency
    /// log. Must roll over at local midnight like the dismissal log
    /// (todayKey) does — the old UTC arithmetic flipped at 5-8pm US time, so
    /// an evening's picks were "shown today" all of the next morning.
    private func todayDayNum() -> Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }

    /// Map of movieID → day number it was last shown in Tonight's Picks.
    private func tonightShownMap() -> [Int: Int] {
        var map: [Int: Int] = [:]
        for entry in tonightShownLog.split(separator: ",") {
            let parts = entry.split(separator: ":")
            if parts.count == 2, let id = Int(parts[0]), let day = Int(parts[1]) {
                map[id] = day
            }
        }
        return map
    }

    /// Record that these movie IDs were shown today; prune entries older than 14 days.
    private func recordTonightShown(_ ids: [Int]) {
        var map = tonightShownMap()
        let today = todayDayNum()
        for id in ids { map[id] = today }
        map = map.filter { $0.value > today - 14 }
        tonightShownLog = map.map { "\($0.key):\($0.value)" }.joined(separator: ",")
    }

    /// Picks the user dismissed today (reset automatically on a new day).
    private func dismissedTonightToday() -> Set<Int> {
        guard tonightDismissedDate == todayKey() else { return [] }
        return Set(tonightDismissedIDs.split(separator: ",").compactMap { Int($0) })
    }

    private func dismissTonight(_ id: Int, toast: Bool = true, suppress: Bool = true) {
        var set = dismissedTonightToday()
        set.insert(id)
        tonightDismissedDate = todayKey()
        tonightDismissedIDs = set.map(String.init).joined(separator: ",")
        withAnimation(.snappy) { tonightCards.removeAll { $0.id == id } }
        // Deliberately clearing the whole deck → hold off on new picks for 24h.
        // Ranking a pick (suppress:false) shouldn't — that's engagement, not "not
        // tonight," so we let fresh picks refill.
        if suppress, tonightCards.isEmpty {
            tonightSuppressedUntil = Date().timeIntervalSince1970 + 24 * 60 * 60
        }
        if toast {
            Haptics.tap()
            // It stays on Want to Watch — this is just "not tonight," not a removal.
            ToastCenter.shared.show("Not tonight — still on your list")
        }
    }

    /// After the rank flow closes, drop any Tonight's Pick that just got ranked
    /// (you've now seen it) — bullet 1 of the deck's behavior.
    private func clearRankedTonightCards() {
        for card in tonightCards where store.isWatched(card.movie.tmdbID) {
            dismissTonight(card.id, toast: false, suppress: false)
        }
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
        lastFeedLoad = Date()
        // Cold start: show the last feed from disk instantly while the
        // fresh one loads — the app never opens to a blank screen.
        if events.isEmpty, let cached = FeedDiskCache.load() {
            events = cached
        }
        if let fresh = try? await SupabaseService.shared.feed() {
            let withNotes = await SupabaseService.shared.attachNotes(to: fresh)
            events = withNotes
            FeedDiskCache.save(withNotes)
            // Fresh server counts supersede any per-thread overrides — keeping
            // them pinned comment counts to a stale value all session.
            commentCountOverrides = [:]
        }
        // Five independent queries — in flight TOGETHER, not one after
        // another (serially this added ~5 round trips of latency before the
        // feed showed as loaded).
        let movieIDs = Array(Set(events.compactMap { $0.movies?.tmdbId }))
        async let liked = SupabaseService.shared.myLikedEventIDs(events.map(\.id))
        async let counts = movieIDs.isEmpty
            ? [:] : SupabaseService.shared.watchlistCounts(movieIDs: movieIDs)
        async let unread = SupabaseService.shared.unreadNotificationCount()
        async let asks = SupabaseService.shared.incomingRecRequests()
        async let watching = SupabaseService.shared.friendsWatching()
        // nil = likes query failed — keep the hearts we have rather than
        // silently un-filling every liked heart for the session.
        if let liked = await liked { likedEventIDs = liked }
        savedCounts = await counts
        unreadCount = await unread
        pendingAsks = (try? await asks) ?? []
        friendsWatchingRows = await watching
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
/// Wraps a feed event id so the "who liked this" sheet is presentable.
struct LikersTarget: Identifiable, Hashable { let id: UUID }

/// Bottom sheet listing everyone who liked a post (CIN feed likes modal).
struct LikersSheet: View {
    let eventID: UUID
    var onOpenMember: (MemberRef) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var likers: [ProfileRow] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            Group {
                if !loaded {
                    SearchSkeleton(kind: .members, rows: 4)
                        .padding(.horizontal, 16)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else if likers.isEmpty {
                    Text("No likes yet — be the first to show some love")
                        .font(.subheadline).foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(likers) { person in
                        Button {
                            dismiss()
                            onOpenMember(MemberRef(id: person.id, username: person.username))
                        } label: {
                            HStack(spacing: 12) {
                                AvatarView(url: person.avatarUrl.flatMap(URL.init), size: 42,
                                           name: preferredName(person.displayName, person.username))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(firstName(person.displayName, person.username) ?? person.username)
                                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                                    Text("@\(person.username)").font(.caption).foregroundStyle(Theme.gray)
                                }
                                Spacer()
                                Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Theme.background)
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle(loaded && !likers.isEmpty ? "Liked by \(likers.count)" : "Likes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            likers = await SupabaseService.shared.likers(eventID: eventID)
            loaded = true
        }
    }
}

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
    /// Open the comment thread — the presenter pushes it onto its nav stack so
    /// it gets native back + swipe-back.
    var onOpenComments: (FeedEventRow, CommentContext) -> Void = { _, _ in }
    /// Live comment count from the presenter (updated when a comment is
    /// added/removed in the pushed thread); falls back to the server count.
    var commentCountOverride: Int? = nil
    /// How many people have this title bookmarked — shown over the bookmark as
    /// social proof, Beli-style ("3 bookmarks").
    var savedCount: Int? = nil
    /// Optional moderation actions. When provided, an ellipsis menu appears in
    /// the header — used on the movie page's "What people think" wall, which can
    /// surface strangers' posts. The feed leaves these nil (no menu).
    var onReport: (() -> Void)? = nil
    var onBlock: (() -> Void)? = nil
    /// Tapping the like count opens the "who liked this" sheet.
    var onShowLikers: (UUID) -> Void = { _ in }

    @State private var liked = false
    @State private var likeInFlight = false
    @State private var heartPop = false
    @State private var likeCount = 0
    @State private var spoilerRevealed = false

    private var movie: Movie? { event.movies?.asMovie }
    /// Count shown on the comment button.
    private var commentCount: Int { commentCountOverride ?? event.commentCount }

    /// A small colored social-proof chip (icon + value).
    private func miniStat(_ icon: String, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundStyle(color)
            Text(text).font(.caption.weight(.semibold)).foregroundStyle(Theme.gray)
        }
    }
    /// The post context handed to the comment thread's header.
    private var commentContext: CommentContext {
        CommentContext(
            actorId: event.userId,
            username: actorUsername,
            displayName: event.profiles?.displayName,
            avatarUrl: event.profiles?.avatarUrl,
            movie: movie,
            actionText: actionText,
            score: event.payload?.score,
            note: nil,
            createdAt: event.createdAt,
            likeCount: likeCount,
            commentCount: commentCount,
            likedByMe: liked
        )
    }
    /// The real handle — used to route to the profile (never the display name).
    private var actorUsername: String { event.profiles?.username ?? "someone" }
    /// Shown in the feed: first name when we have one, else the username.
    private var actorName: String {
        let display = event.profiles?.displayName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !display.isEmpty {
            return display.split(separator: " ").first.map(String.init) ?? display
        }
        return actorUsername
    }

    private func openActor() {
        onOpenMember(MemberRef(id: event.userId, username: actorUsername))
    }

    /// Toggle the like with optimistic UI + revert on failure (shared by the
    /// heart button and the double-tap gesture).
    private func toggleLike() {
        guard !likeInFlight else { return }
        likeInFlight = true
        Haptics.tap()
        liked.toggle()
        likeCount += liked ? 1 : -1
        Task {
            defer { likeInFlight = false }
            do { try await SupabaseService.shared.toggleLike(eventID: event.id, like: liked) }
            catch {
                liked.toggle()
                likeCount += liked ? 1 : -1
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

    /// The verb between the name and the title — also handed to the comments
    /// header so the post reads the same there.
    private var actionText: String {
        switch event.eventType {
        case "ranked":      return "ranked"
        case "watchlisted": return "bookmarked"
        case "noted":       return "wrote about"
        default:            return "shared an update"
        }
    }

    /// The post headline as one flowing run: a bold, tappable name (the name is
    /// a link routed to the author's profile by the openURL handler on the Text)
    /// then the action and the bold title. Kept as a single Text so long titles
    /// wrap cleanly instead of stair-stepping under a separate name view.
    private static let authorLink = URL(string: "cinifeed://author")!

    private var headlineAttr: AttributedString {
        var name = AttributedString(actorName)
        name.inlinePresentationIntent = .stronglyEmphasized
        name.link = Self.authorLink
        // One verb source (actionText) — the card and the comments header
        // must never disagree on how an event reads.
        guard event.eventType == "ranked" || event.eventType == "watchlisted"
                || event.eventType == "noted" else {
            return name + AttributedString(" \(actionText)")
        }
        var title = AttributedString(movie?.title ?? "a movie")
        title.inlinePresentationIntent = .stronglyEmphasized
        return name + AttributedString(" \(actionText) ") + title
    }

    /// The note shown under a ranking. Spoilers blur behind a tap-to-reveal
    /// chip; otherwise the note reads as a plain quote (tapping the chip wins
    /// its own tap, so it never falls through to the card's open-movie gesture).
    @ViewBuilder
    private func noteView(_ note: String) -> some View {
        if event.noteContainsSpoilers == true && !spoilerRevealed {
            Button {
                Haptics.tap()
                withAnimation(.snappy) { spoilerRevealed = true }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "eye.slash")
                    Text("Contains spoilers — tap to reveal")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            }
            .buttonStyle(.plain)
        } else {
            // Bold "Notes:" lead-in, exactly like the movie page's notes wall.
            (Text("Notes: ").bold() + Text(note))
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
                .lineLimit(6)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    openActor()
                } label: {
                    AvatarView(url: event.profiles?.avatarUrl.flatMap(URL.init), size: 48,
                               name: preferredName(event.profiles?.displayName, event.profiles?.username))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 4) {
                    // One flowing line (name + the rest) so long titles wrap
                    // cleanly. The name is a tappable link → the author's
                    // profile; taps anywhere else on the card open the movie.
                    Text(headlineAttr)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                        .tint(Theme.ink)   // the name link reads as bold ink, not blue
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .environment(\.openURL, OpenURLAction { _ in
                            openActor(); return .handled
                        })
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
                if onReport != nil || onBlock != nil {
                    Menu {
                        if let onReport {
                            Button(role: .destructive, action: onReport) {
                                Label("Report this post", systemImage: "flag")
                            }
                        }
                        if let onBlock {
                            Button(role: .destructive, action: onBlock) {
                                Label("Block @\(actorUsername)", systemImage: "hand.raised")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .padding(.leading, 4)
                            .frame(height: 44)
                            .contentShape(Rectangle())
                    }
                }
            }

            // The author's note on this rating, Beli-style. Spoiler notes stay
            // blurred behind a tap, exactly like the movie page's notes wall.
            if let note = event.note, !note.isEmpty {
                noteView(note)
            }

            // Social proof — small indicators for likes / comments on the left,
            // and a low-key "N bookmarks" count on the right (Beli-style: quiet
            // grey text, not a loud badge over the poster).
            if likeCount > 0 || commentCount > 0 || (savedCount ?? 0) > 0 {
                HStack(spacing: 14) {
                    if likeCount > 0 {
                        Button { onShowLikers(event.id) } label: {
                            miniStat("heart.fill", "\(likeCount)", .red)
                        }
                    }
                    if commentCount > 0 {
                        Button { onOpenComments(event, commentContext) } label: {
                            miniStat("bubble.right.fill", "\(commentCount)", Theme.marquee)
                        }
                    }
                    Spacer(minLength: 0)
                    if let savedCount, savedCount > 0 {
                        Text("\(savedCount) \(savedCount == 1 ? "bookmark" : "bookmarks")")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
            }

            // The big icons reflect only what YOU did: the heart fills when you
            // like; comment and share are actions, never filled by others.
            HStack(spacing: 22) {
                Button { toggleLike() } label: {
                    Image(systemName: liked ? "heart.fill" : "heart")
                        .foregroundStyle(liked ? .red : Theme.ink)
                }
                .accessibilityLabel(liked ? "Unlike" : "Like")
                Button { onOpenComments(event, commentContext) } label: {
                    Image(systemName: "bubble.right").foregroundStyle(Theme.ink)
                }
                .accessibilityLabel("Comments")
                if let movie {
                    ShareLink(item: "\(movie.title) — on Cini 🎬\n\(AppLinks.titleLink(movie.tmdbID))") {
                        Image(systemName: "paperplane")
                            .foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Share")
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
        // Same corner as the movie page: (+) / bookmark on the artwork. The
        // bookmark COUNT is shown quietly in the engagement row above (Beli's
        // low-key "N bookmarks"), not as a loud badge over the poster.
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
        // Adopt the server like count on first render and reconcile to it on
        // every refresh — but never while our own like/unlike is still in
        // flight, or a refresh that lands before the write completes would
        // clobber the optimistic count back to the stale server snapshot.
        .onChange(of: event.likeCount, initial: true) { _, count in
            guard !likeInFlight else { return }
            likeCount = count
        }
    }
}

// MARK: - Comments

/// The originating post shown at the top of the comments view, so the screen
/// reads as a full thread (post → comments) rather than a bare list. Built by
/// whoever opens the sheet — the feed from its event, the movie page from a
/// public note.
struct CommentContext {
    let actorId: UUID
    let username: String
    var displayName: String?
    var avatarUrl: String?
    var movie: Movie?
    /// "ranked", "wants to watch", … — the verb between name and title.
    var actionText: String = "ranked"
    var score: Double?
    var note: String?
    var containsSpoilers: Bool = false
    var createdAt: Date
    var likeCount: Int = 0
    var commentCount: Int = 0
    var likedByMe: Bool = false
}

/// A pushable comment thread: the event id to load plus its post header context.
/// Hashable on the id alone so it can drive `navigationDestination(item:)`.
/// `context` may be nil when opening cold from a push — the sheet self-fetches.
struct CommentsLink: Identifiable, Hashable {
    let id: UUID
    /// The post header pinned atop the thread. Nil (e.g. opened from a
    /// notification) falls back to the bare comment list.
    var context: CommentContext? = nil
    static func == (lhs: CommentsLink, rhs: CommentsLink) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension CommentContext {
    /// Build a context from a fetched feed event (used when opening a comment
    /// thread cold from a push notification or the notifications screen).
    init(event: FeedEventRow, likedByMe: Bool) {
        actorId = event.userId
        username = event.profiles?.username ?? ""
        displayName = event.profiles?.displayName
        avatarUrl = event.profiles?.avatarUrl
        movie = event.movies?.asMovie
        actionText = event.eventType == "watchlisted" ? "saved" : "ranked"
        score = event.payload?.score
        note = event.note
        containsSpoilers = event.noteContainsSpoilers ?? false
        createdAt = event.createdAt
        likeCount = event.likeCount
        commentCount = event.commentCount
        self.likedByMe = likedByMe
    }
}

struct CommentsSheet: View {
    /// Comments hang off a feed event — the feed passes its card's event,
    /// the movie page passes the 'ranked' event behind a public rating.
    let eventID: UUID
    /// The post being discussed, pinned to the top of the thread. Nil falls back
    /// to the bare comment list.
    var context: CommentContext? = nil
    /// Tapping a commenter routes to their profile in the PRESENTER's nav stack
    /// (after this sheet dismisses) — never a cramped profile pushed inside the
    /// comments sheet.
    var onOpenMember: (MemberRef) -> Void = { _ in }
    /// Reports the live comment count to the presenter so its badge stays
    /// accurate as comments are added/removed.
    var onCommentCountChange: (Int) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    @FocusState private var composerFocused: Bool
    @State private var comments: [CommentRow] = []
    @State private var draft = ""
    @State private var loaded = false
    @State private var blockCandidate: CommentRow?
    /// The comment being replied to — drives the "Replying to…" bar and seeds
    /// the composer with their @handle.
    @State private var replyingTo: CommentRow?
    // Header like state, seeded from the context and owned optimistically after.
    @State private var headerLiked = false
    @State private var headerLikeCount = 0
    @State private var headerLikeInFlight = false
    @State private var headerSeeded = false
    @State private var noteRevealed = false
    // Feed events don't carry the note inline; fetch it for the header when the
    // context didn't supply one (the movie page already passes its note).
    @State private var fetchedNote: String?
    // When opened cold (no context passed — e.g. from push), the event is
    // fetched and its context built here for the Beli-style header.
    @State private var fetchedContext: CommentContext?

    private var activeContext: CommentContext? { context ?? fetchedContext }

    // Pushed onto the presenter's navigation stack, so it gets a native back
    // button and edge-swipe-back for free (like opening a profile).
    var body: some View {
        List {
                // The post being discussed, pinned on top so the screen reads
                // as a full thread (Beli-style) instead of a bare comment list.
                if let ctx = activeContext {
                    postHeader(ctx)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                        .listRowInsets(EdgeInsets(top: 14, leading: 16, bottom: 8, trailing: 16))
                }

                if !loaded {
                    ListSkeleton(rows: 5)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                } else if comments.isEmpty {
                    Text("No comments yet — say something nice.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 10)
                        .listRowSeparator(.hidden)
                        .listRowBackground(Theme.background)
                } else {
                    ForEach(comments) { comment in
                        commentRow(comment)
                    }
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
            // safeAreaInset keeps the composer pinned ABOVE the keyboard.
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 0) {
                    // "Replying to <name>" context, with a cancel ✕.
                    if let replyingTo {
                        HStack(spacing: 8) {
                            Text("Replying to \(firstName(replyingTo.profiles?.displayName, replyingTo.profiles?.username) ?? "member")")
                                .font(.caption).foregroundStyle(Theme.gray)
                            Spacer()
                            Button { cancelReply() } label: {
                                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(Theme.gray)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Cancel reply")
                        }
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Theme.fill.opacity(0.5))
                        Divider().overlay(Theme.hairline)
                    }
                    // @-mention autocomplete: appears while typing an @handle.
                    if !mentionSuggestions.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(mentionSuggestions) { friend in
                                    Button { insertMention(friend) } label: {
                                        HStack(spacing: 6) {
                                            AvatarView(url: friend.avatarUrl.flatMap(URL.init), size: 22,
                                                       name: preferredName(friend.displayName, friend.username))
                                            Text("@\(friend.username)").font(.subheadline).foregroundStyle(Theme.ink)
                                        }
                                        .padding(.horizontal, 10).padding(.vertical, 6)
                                        .background(Capsule().fill(Theme.fill))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                        Divider().overlay(Theme.hairline)
                    }
                    HStack(spacing: 10) {
                        // Your avatar leads the composer, Beli-style — it's
                        // clearly YOU about to comment.
                        AvatarView(url: session.profile?.avatarURL, size: 32,
                                   name: preferredName(session.profile?.displayName,
                                                       session.profile?.username))
                        TextField("Comment or tag a friend", text: $draft, axis: .vertical)
                            .focused($composerFocused)
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
                        .accessibilityLabel("Post comment")
                    }
                    .padding(12)
                }
                .background(.thinMaterial)
            }
            .navigationTitle("Comments")
            .navigationBarTitleDisplayMode(.inline)
            // Full-page like Beli — no tab bar peeking under the composer.
            .toolbar(.hidden, for: .tabBar)
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
        .task {
            FriendsCache.shared.refreshIfStale()   // power the @-mention picker
            // Cold open from a push or the notifications screen: no context was
            // passed, so fetch the event and build the Beli-style header here.
            if context == nil, fetchedContext == nil {
                if let event = await SupabaseService.shared.feedEvent(id: eventID) {
                    let liked = await SupabaseService.shared.didLike(eventID: eventID)
                    let ctx = CommentContext(event: event, likedByMe: liked)
                    fetchedContext = ctx
                    if !headerSeeded {
                        headerLiked = liked
                        headerLikeCount = event.likeCount
                        headerSeeded = true
                    }
                }
            }
            await reload()
            // Backfill the note for the header when the caller couldn't supply
            // one (feed posts), so the thread shows the review like Beli.
            if let c = activeContext, c.note == nil, fetchedNote == nil, let m = c.movie {
                fetchedNote = await SupabaseService.shared.note(userID: c.actorId, movieID: m.tmdbID)
            }
        }
        // Seed the header's like state from the context once; the heart owns it
        // optimistically after that.
        .onAppear {
            if let ctx = activeContext, !headerSeeded {
                headerLiked = ctx.likedByMe
                headerLikeCount = ctx.likeCount
                headerSeeded = true
            }
        }
    }

    // MARK: Post header (the thing being commented on)

    @ViewBuilder private func postHeader(_ c: CommentContext) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Button {
                    onOpenMember(MemberRef(id: c.actorId, username: c.username))
                } label: {
                    AvatarView(url: c.avatarUrl.flatMap(URL.init), size: 44,
                               name: preferredName(c.displayName, c.username))
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 3) {
                    // Bold, tappable name (→ profile) + the rest of the sentence,
                    // same treatment as the feed card.
                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Button {
                            onOpenMember(MemberRef(id: c.actorId, username: c.username))
                        } label: {
                            Text(firstName(c.displayName, c.username) ?? c.username)
                                .bold().foregroundStyle(Theme.ink)
                        }
                        .buttonStyle(.plain)
                        (Text(" \(c.actionText) ") + Text(c.movie?.title ?? "").bold())
                            .foregroundStyle(Theme.ink)
                    }
                    .font(.subheadline)
                    .lineLimit(3)
                    if let movie = c.movie {
                        Text([movie.genres.first, movie.releaseYear.map(String.init)]
                            .compactMap(\.self).joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                }
                Spacer(minLength: 0)
                if let score = c.score {
                    ScoreBadge(score: score, size: 44)
                }
            }

            if let note = (c.note ?? fetchedNote), !note.isEmpty {
                if c.containsSpoilers && !noteRevealed {
                    Button {
                        Haptics.tap()
                        withAnimation(.snappy) { noteRevealed = true }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "eye.slash")
                            Text("Contains spoilers — tap to reveal")
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.gray)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
                    }
                    .buttonStyle(.plain)
                } else {
                    (Text("Notes: ").bold() + Text(note)).font(.subheadline)
                }
            }

            HStack(spacing: 18) {
                Button { toggleHeaderLike() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: headerLiked ? "heart.fill" : "heart")
                            .foregroundStyle(headerLiked ? .red : Theme.ink)
                        if headerLikeCount > 0 {
                            Text("\(headerLikeCount)").font(.subheadline.weight(.medium))
                        }
                    }
                }
                if let movie = c.movie {
                    ShareLink(item: "\(movie.title) — on Cini 🎬\n\(AppLinks.titleLink(movie.tmdbID))") {
                        Image(systemName: "paperplane").foregroundStyle(Theme.ink)
                    }
                    .accessibilityLabel("Share")
                }
                Spacer()
                Text(c.createdAt.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
            }
            .foregroundStyle(Theme.ink)
            .buttonStyle(.plain)

            Divider().overlay(Theme.hairline).padding(.top, 2)
        }
    }

    private func toggleHeaderLike() {
        // Same in-flight guard as FeedCard: a double-tap would race two writes
        // whose server order isn't guaranteed.
        guard !headerLikeInFlight else { return }
        headerLikeInFlight = true
        Haptics.tap()
        headerLiked.toggle()
        headerLikeCount += headerLiked ? 1 : -1
        Task {
            defer { headerLikeInFlight = false }
            do { try await SupabaseService.shared.toggleLike(eventID: eventID, like: headerLiked) }
            catch {
                headerLiked.toggle()
                headerLikeCount += headerLiked ? 1 : -1
                ToastCenter.shared.saveFailed()
            }
        }
    }

    // MARK: @mention helpers

    /// Compiled once and reused — building it per comment row per render was
    /// needless work on long threads.
    private static let mentionPattern = try! NSRegularExpression(pattern: "@([A-Za-z0-9_]+)")

    /// Parse @handles in a comment body and make each one a tappable link
    /// using a `cini-mention://open?u=<handle>` URL that we intercept inline.
    static func attributedBody(_ body: String) -> AttributedString {
        var result = AttributedString()
        let pattern = Self.mentionPattern
        let nsBody = body as NSString
        var lastEnd = 0
        for match in pattern.matches(in: body, range: NSRange(body.startIndex..<body.endIndex, in: body)) {
            let prefixRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
            if prefixRange.length > 0 {
                result += AttributedString(nsBody.substring(with: prefixRange))
            }
            let handle = nsBody.substring(with: match.range(at: 1))
            var mention = AttributedString("@\(handle)")
            mention.font = .system(size: 15, weight: .semibold)
            if let url = URL(string: "cini-mention://open?u=\(handle)") {
                mention.link = url
            }
            result += mention
            lastEnd = match.range.location + match.range.length
        }
        if lastEnd < nsBody.length {
            result += AttributedString(nsBody.substring(from: lastEnd))
        }
        return result
    }

    /// Tap on a @mention → look up the user and open their profile.
    private func openMention(_ handle: String) {
        // Fast path: they're in the following cache.
        if let cached = FriendsCache.shared.following.first(where: {
            $0.username.caseInsensitiveCompare(handle) == .orderedSame
        }) {
            onOpenMember(MemberRef(id: cached.id, username: cached.username))
            return
        }
        // Slow path: look up the profile by username.
        Task {
            if let id = await SupabaseService.shared.profileID(username: handle) {
                await MainActor.run {
                    onOpenMember(MemberRef(id: id, username: handle))
                }
            }
        }
    }

    // MARK: One comment

    @ViewBuilder private func commentRow(_ comment: CommentRow) -> some View {
        HStack(alignment: .top, spacing: 12) {
            // A plain Button (not a List NavigationLink, which injects a
            // disclosure chevron and breaks the row layout) — hand the member to
            // the presenter so the real profile opens in the main nav stack.
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
                    Text(firstName(comment.profiles?.displayName, comment.profiles?.username) ?? "member")
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(comment.createdAt.formatted(.relative(presentation: .named)))
                        .font(.caption2)
                        .foregroundStyle(Theme.gray)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
                Text(Self.attributedBody(comment.body))
                    .font(.subheadline)
                    .tint(Theme.marquee)
                    .environment(\.openURL, OpenURLAction { url in
                        guard url.scheme == "cini-mention",
                              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
                              let handle = comps.queryItems?.first(where: { $0.name == "u" })?.value
                        else { return .systemAction }
                        openMention(handle)
                        return .handled
                    })
                Button { startReply(to: comment) } label: {
                    Text("Reply").font(.caption.weight(.semibold)).foregroundStyle(Theme.gray)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
            Spacer(minLength: 8)
            // Like a single comment, Beli-style.
            Button { toggleCommentLike(comment) } label: {
                VStack(spacing: 2) {
                    Image(systemName: comment.likedByMe ? "heart.fill" : "heart")
                        .font(.footnote)
                        .foregroundStyle(comment.likedByMe ? .red : Theme.gray)
                        .symbolEffect(.bounce, value: comment.likedByMe)
                    if comment.likeCount > 0 {
                        Text("\(comment.likeCount)")
                            .font(.caption2)
                            .foregroundStyle(Theme.gray)
                    }
                }
                // A comfortable hit target (the bare icon was too small to tap).
                .frame(minWidth: 44, minHeight: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(comment.likedByMe ? "Unlike comment" : "Like comment")
        }
        .listRowBackground(Theme.background)
        // Swipe left to delete your own comment (Undo offered after).
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            if comment.userId == SupabaseService.shared.currentUserID {
                Button(role: .destructive) {
                    deleteComment(comment)
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
        // Long-press: delete your own, moderate others'.
        .contextMenu {
            if comment.userId == SupabaseService.shared.currentUserID {
                Button(role: .destructive) {
                    deleteComment(comment)
                } label: {
                    Label("Delete my comment", systemImage: "trash")
                }
            }
            Button(role: .destructive) {
                Task {
                    let ok = await SupabaseService.shared.report(
                        kind: "comment", subjectID: comment.id.uuidString)
                    if ok { ToastCenter.shared.show("Reported — we'll review it") }
                    else { ToastCenter.shared.saveFailed() }
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

    private func toggleCommentLike(_ comment: CommentRow) {
        guard let idx = comments.firstIndex(where: { $0.id == comment.id }) else { return }
        Haptics.tap()
        let liking = !comments[idx].likedByMe
        comments[idx].likedByMe = liking
        comments[idx].likeCount = max(0, comments[idx].likeCount + (liking ? 1 : -1))
        Task {
            do {
                try await SupabaseService.shared.toggleCommentLike(commentID: comment.id, like: liking)
            } catch {
                if let i = comments.firstIndex(where: { $0.id == comment.id }) {
                    comments[i].likedByMe = !liking
                    comments[i].likeCount = max(0, comments[i].likeCount + (liking ? -1 : 1))
                }
                ToastCenter.shared.saveFailed()
            }
        }
    }

    private func reload() async {
        comments = (try? await SupabaseService.shared.comments(eventID: eventID)) ?? []
        loaded = true
        onCommentCountChange(comments.count)
    }

    private func post() async {
        let body = draft.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return }
        draft = ""
        replyingTo = nil
        do {
            try await SupabaseService.shared.comment(eventID: eventID, body: body)
            await notifyMentions(in: body)
        } catch {
            draft = body   // give the text back instead of eating it
            ToastCenter.shared.saveFailed()
        }
        await reload()
    }

    /// Reply prefills the composer with the commenter's @handle (which tags them
    /// via the normal mention flow) and shows the "Replying to…" bar.
    private func startReply(to comment: CommentRow) {
        let handle = comment.profiles?.username ?? "member"
        replyingTo = comment
        draft = "@\(handle) "
        composerFocused = true
    }

    private func cancelReply() {
        replyingTo = nil
        draft = ""
        composerFocused = false
    }

    private func deleteComment(_ comment: CommentRow) {
        Task {
            do {
                try await SupabaseService.shared.deleteComment(id: comment.id)
                // Offer Undo (re-post) — matches the app's other destructive removals.
                let body = comment.body
                let eid = eventID
                ToastCenter.shared.showUndo("Comment deleted") {
                    Task {
                        do {
                            try await SupabaseService.shared.comment(eventID: eid, body: body)
                            await reload()
                        } catch {
                            // The toast implied restoration — don't let a failed
                            // re-post leave the comment silently deleted.
                            ToastCenter.shared.saveFailed()
                        }
                    }
                }
                await reload()
            } catch {
                ToastCenter.shared.saveFailed()
            }
        }
    }

    // MARK: @-mentions

    /// The handle being typed right now (text after the last '@' with no space),
    /// or nil when the cursor isn't in a mention.
    private var mentionQuery: String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        let after = draft[draft.index(after: at)...]
        if after.contains(where: { $0 == " " || $0 == "\n" }) { return nil }
        return String(after)
    }

    private var mentionSuggestions: [ProfileRow] {
        guard let q = mentionQuery else { return [] }
        let ql = q.lowercased()
        let friends = FriendsCache.shared.following
        let matches = ql.isEmpty ? friends : friends.filter {
            $0.username.lowercased().hasPrefix(ql) || $0.displayName.lowercased().contains(ql)
        }
        return Array(matches.prefix(6))
    }

    private func insertMention(_ friend: ProfileRow) {
        guard let at = draft.lastIndex(of: "@") else { return }
        draft = String(draft[..<at]) + "@\(friend.username) "
    }

    /// Resolve @handles in the posted body and tag them. Handles match against
    /// followed members AND this thread's commenters — a Reply to someone you
    /// don't follow (a stranger commenting on your post) must still tag them.
    private func notifyMentions(in body: String) async {
        let names = Self.mentionedUsernames(in: body)
        guard !names.isEmpty else { return }
        var ids = Set(FriendsCache.shared.following
            .filter { names.contains($0.username.lowercased()) }
            .map(\.id))
        for comment in comments {
            if let handle = comment.profiles?.username.lowercased(), names.contains(handle) {
                ids.insert(comment.userId)
            }
        }
        await SupabaseService.shared.notifyMention(eventID: eventID, userIDs: Array(ids))
    }

    static func mentionedUsernames(in body: String) -> Set<String> {
        guard let re = try? NSRegularExpression(pattern: "@([A-Za-z0-9_]+)") else { return [] }
        let ns = body as NSString
        var names: Set<String> = []
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            names.insert(ns.substring(with: m.range(at: 1)).lowercased())
        }
        return names
    }
}

// MARK: - Stubs reached from the header

struct NotificationsView: View {
    @Environment(TabRouter.self) private var tabRouter
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [NotificationRow] = []
    @State private var loaded = false
    @State private var loadFailed = false
    @State private var reloadKey = 0
    @State private var detailMovie: Movie?
    @State private var memberTarget: MemberRef?
    @State private var commentsLink: CommentsLink?
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
            if rows.isEmpty && loadFailed {
                // A failed fetch is NOT "nothing yet" — offer a retry instead
                // of the friend-less zero state.
                EmptyStateView(
                    icon: "wifi.exclamationmark",
                    title: "Couldn't load notifications",
                    message: "Check your connection and try again.",
                    actionTitle: "Try again") { reloadKey += 1 }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            } else if rows.isEmpty && loaded {
                EmptyStateView(
                    icon: "bell",
                    title: "Nothing yet",
                    message: "Likes, comments, and friends' activity show up here. Add a few friends to get things moving.",
                    actionTitle: "Find friends") {
                        tabRouter.openMembersSearch = true
                        tabRouter.selection = .search
                        dismiss()
                    }
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            }
            // Beli-style grouping: unread first under "New", the rest "Earlier".
            if !unread.isEmpty {
                Section("New") { ForEach(unread) { notificationRow($0) } }
            }
            if !earlier.isEmpty {
                Section("Earlier") { ForEach(earlier) { notificationRow($0) } }
            }
        }
        .listStyle(.plain)
        .nativeContentWidth()   // cap width so rows don't stretch on iPad
        .background(Theme.background)
        // Tapped a name link in a headline → open that member's profile.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "cinimember" else { return .systemAction }
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            guard let idStr = items?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: idStr) else { return .discarded }
            let username = items?.first(where: { $0.name == "u" })?.value ?? ""
            memberTarget = MemberRef(id: id, username: username)
            return .handled
        })
        .navigationDestination(item: $detailMovie) { movie in
            MovieDetailView(movie: movie)
        }
        .navigationDestination(item: $memberTarget) { member in
            MemberProfileView(userID: member.id, username: member.username)
        }
        .navigationDestination(item: $commentsLink) { link in
            CommentsSheet(eventID: link.id, context: link.context,
                          onOpenMember: { memberTarget = $0 })
        }
        .sheet(isPresented: $showRespondRecs) {
            RespondRecSheet()
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadKey) {
            // Mark-read ONLY after a successful fetch. Marking on failure
            // flagged every unread notification as read without the user
            // ever seeing one.
            do {
                rows = try await SupabaseService.shared.notifications()
                loaded = true
                loadFailed = false
                await SupabaseService.shared.markNotificationsRead()
                try? await UNUserNotificationCenter.current().setBadgeCount(0)
            } catch {
                if !Task.isCancelled {
                    loadFailed = true
                    loaded = true
                }
            }
        }
    }

    /// Unread (what's new since last visit) vs already-seen. Rows are fetched
    /// before they're marked read, so this reflects state on open.
    private var unread: [NotificationRow] { rows.filter { $0.readAt == nil } }
    private var earlier: [NotificationRow] { rows.filter { $0.readAt != nil } }

    @ViewBuilder
    private func notificationRow(_ row: NotificationRow) -> some View {
        HStack(spacing: 12) {
            Button {
                if let actorId = row.actorId, let actor = row.actor {
                    memberTarget = MemberRef(id: actorId, username: actor.username)
                }
            } label: {
                if row.actor == nil {
                    // System notifications (streak, showtime, streaming) have no
                    // person — show a themed glyph instead of a blank initials disc.
                    ZStack {
                        Circle().fill(Theme.gold.opacity(0.16)).frame(width: 42, height: 42)
                        Image(systemName: systemIcon(for: row.kind))
                            .font(.headline).foregroundStyle(Theme.gold)
                    }
                } else {
                    AvatarView(url: row.actor?.avatarUrl.flatMap(URL.init), size: 42,
                       name: preferredName(row.actor?.displayName, row.actor?.username))
                }
            }
            .buttonStyle(.plain)
            .disabled(row.actor == nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline(row)).font(.subheadline).lineLimit(3)
                if let message = row.message, !message.isEmpty {
                    Text("“\(message)”").font(.subheadline).italic()
                        .foregroundStyle(Theme.ink.opacity(0.9)).lineLimit(3)
                }
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
                if let path = row.movies?.posterPath, let movie = movieStub(row) {
                    Button { detailMovie = movie } label: {
                        PosterView(url: TMDBService.imageURL(path: path, size: .poster), width: 32)
                    }
                    .buttonStyle(.plain)
                }
                if row.readAt == nil {
                    Circle().fill(Theme.marquee).frame(width: 8, height: 8)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { route(row) }
        .listRowBackground(Theme.background)
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive) {
                let id = row.id
                let removed = row
                withAnimation { rows.removeAll { $0.id == id } }
                Task {
                    // Put the row back (and tell the user) if the delete failed,
                    // instead of letting it silently reappear on the next fetch.
                    if !(await SupabaseService.shared.deleteNotification(id)) {
                        withAnimation { rows.append(removed); rows.sort { $0.createdAt > $1.createdAt } }
                        ToastCenter.shared.saveFailed()
                    }
                }
            } label: { Label("Delete", systemImage: "trash") }
        }
    }

    /// A glyph for notifications that have no person behind them.
    private func systemIcon(for kind: String) -> String {
        switch kind {
        case "streak_reminder": return "flame.fill"
        case "watchlist_showing": return "ticket.fill"
        case "streaming_now": return "play.tv.fill"
        case "season_premiere": return "tv.fill"
        case "tonight_pick": return "popcorn.fill"
        case "rate_nudge": return "star.fill"
        default: return "bell.fill"
        }
    }

    /// Deep-link a tapped notification to the area it's about.
    private func route(_ row: NotificationRow) {
        if row.kind == "rec_request" {
            showRespondRecs = true
        } else if row.kind == "streak_reminder" {
            // No movie/actor of its own — send them to Recs, where ranking the
            // streak-saver is one tap away (matches the push tap behavior).
            dismiss()
            tabRouter.selection = .swipe
        } else if ["comment", "mention", "like"].contains(row.kind), let eventId = row.eventId {
            // Land on the actual activity/thread — not the bare movie page.
            commentsLink = CommentsLink(id: eventId)
        } else if ["watch_match", "watch_invite"].contains(row.kind),
                  let movieId = row.movieId, let actorId = row.actorId, let actor = row.actor {
            // Same as tapping the push: open the Plan-a-Watch sheet for that
            // title + friend — the bare movie page has no accept/decline flow.
            dismiss()
            tabRouter.pendingWatchPlan = WatchPlanContext(
                movieID: movieId,
                friend: MemberRef(id: actorId, username: actor.username))
        } else if let actorId = row.actorId, let movieId = row.movieId,
                  let eventType = activityEventType(for: row.kind) {
            // Rank/save notification → look up the actor's event so the comment
            // thread opens with the Beli-style header. Falls back to movie page.
            Task {
                if let event = await SupabaseService.shared.activityEvent(
                    actorID: actorId, movieID: movieId, eventType: eventType) {
                    let liked = await SupabaseService.shared.didLike(eventID: event.id)
                    let ctx = CommentContext(event: event, likedByMe: liked)
                    await MainActor.run {
                        commentsLink = CommentsLink(id: event.id, context: ctx)
                    }
                } else {
                    await MainActor.run { detailMovie = movieStub(row) }
                }
            }
        } else if let stub = movieStub(row) {
            detailMovie = stub
        } else if let actorId = row.actorId, let actor = row.actor {
            memberTarget = MemberRef(id: actorId, username: actor.username)
        }
    }

    /// Map notification kinds that link to a ranked/saved event → feed_events event_type.
    private func activityEventType(for kind: String) -> String? {
        switch kind {
        case "friend_ranked_watchlist_movie", "friend_loved", "rec_watched": return "ranked"
        case "saved_your_rank": return "watchlisted"
        default: return nil
        }
    }

    /// Build a minimal Movie from a notification's embedded stub (for navigating
    /// to the movie page without a full TMDB round-trip).
    private func movieStub(_ row: NotificationRow) -> Movie? {
        guard let movieId = row.movieId, let stub = row.movies else { return nil }
        return Movie(tmdbID: movieId,
                     mediaKind: movieId < 0 ? "tv" : "movie",
                     title: stub.title,
                     releaseYear: nil, posterPath: stub.posterPath,
                     backdropPath: nil, genres: [], certification: nil,
                     runtimeMinutes: nil, director: nil, overview: nil)
    }

    private func headline(_ row: NotificationRow) -> AttributedString {
        let who = "@\(row.actor?.username ?? "someone")"
        // For "joined"/follow events, prefer the person's real profile name — a
        // brand-new user reads like someone you know by name, not an
        // auto-generated handle. Falls back to the @handle if they have no name.
        let name = (row.actor?.displayName).flatMap { $0.isEmpty ? nil : $0 } ?? who
        let movie = row.movies?.title ?? "a movie"
        let text: String
        switch row.kind {
        case "new_follower": text = "**\(name)** started following you"
        case "like": text = "**\(who)** liked your activity on **\(movie)**"
        case "comment": text = "**\(who)** commented on **\(movie)**"
        case "friend_ranked_watchlist_movie": text = "**\(who)** ranked **\(movie)** — it's on your Want to Watch list"
        case "watchlist_showing": text = "**\(movie)** from your Want to Watch is in theaters near you — tickets go fast 🎟️"
        case "invite_joined": text = "**\(name)** joined Cini from your invite — you now follow each other 🎉"
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
        case "rec_passed": text = "**\(who)** passed on **\(movie)** you recommended"
        case "rec_watched": text = "**\(who)** watched **\(movie)** you recommended 🎬"
        case "mention": text = "**\(who)** mentioned you in a comment on **\(movie)**"
        case "friend_loved": text = "**\(who)** just ranked **\(movie)** — one of your favorites 🍿"
        case "friend_watching": text = "**\(who)** started watching **\(movie)** — you're watching it too 📺"
        case "caught_up": text = "**\(who)** is all caught up on **\(movie)** 🎉"
        default: text = "**\(who)** did something new"
        }
        var attr = (try? AttributedString(markdown: text)) ?? AttributedString(text)
        // Tapping the actor's name opens their profile (the avatar already does).
        // Attach a custom-scheme link to just the name run — the List's openURL
        // handler routes it — and tint it so it reads as tappable.
        if let actorId = row.actorId, let actor = row.actor {
            // Kinds whose headline renders the display name instead of @handle.
            let token = ["contact_joined", "new_follower", "invite_joined"].contains(row.kind)
                ? name : who
            if let r = attr.range(of: token) {
                var comps = URLComponents()
                comps.scheme = "cinimember"
                comps.host = "open"
                comps.queryItems = [
                    .init(name: "id", value: actorId.uuidString),
                    .init(name: "u", value: actor.username)
                ]
                if let url = comps.url {
                    attr[r].link = url
                    attr[r].foregroundColor = Theme.velvet
                }
            }
        }
        return attr
    }
}
