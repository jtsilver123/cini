import SwiftUI
import RankingEngine

/// The Swipe tab — a Tinder-style way to triage what to watch next. Two
/// presentations of the same personalized pool: a card deck (default) and a
/// grid, toggled top-right. Swipe right (or ♥) saves to Want to Watch, left
/// (or ✕) passes, and the gold + ranks one you've already seen (the real
/// head-to-head flow). Movies and TV each get their own deck via the toggle.
///
/// Reuses the shared `RecCardDeck` (cards) and `SuggestionGrid` (grid) so the
/// save / pass / rank gestures are identical to everywhere else in the app.
struct SwipeView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter

    @State private var candidates: [YourListsView.RecCandidate] = []
    @State private var loaded = false
    /// Grid (pick from posters — best for ranking things you've watched) or
    /// Cards (the swipe deck — best for finding things to watch). Persisted so
    /// the choice sticks, and auto-selected by the deep link that opened Recs.
    private enum Layout: String, CaseIterable {
        case grid, cards
    }
    @AppStorage("swipe.layout") private var layout: Layout = .cards
    @State private var suggestTV = false
    @State private var dismissed: Set<Int> = []
    /// Titles you've passed or saved from Recs — persisted so they don't come
    /// back when you leave and return (or the deck rebuilds). Applied when the
    /// pool is built, not in `visible`, so a live swipe doesn't shrink the deck
    /// array mid-animation (which would skip the next card).
    @AppStorage("swipe.dismissedIDs") private var dismissedRaw = ""
    @State private var filters = MovieFilters()
    @State private var showFilterSheet = false
    @State private var bookmarkCounts: [Int: Int] = [:]
    @AppStorage("swipe.importBannerHidden") private var importBannerHidden = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var watchedCountAtRank = 0
    /// The title most recently sent into the rank flow — so the post-rank toast
    /// can offer to open its page.
    @State private var lastRanked: Movie?
    @State private var showImport = false
    /// Bumped each time the pool reloads (filter change / refresh) so the deck
    /// resets to the first card instead of keeping a stale index.
    @State private var poolVersion = 0
    /// Identifies the in-flight pool load; a newer load supersedes an older one
    /// so two quick filter changes can't let stale results win the race.
    @State private var loadSeq = 0
    /// Same idea one level up: identifies the in-flight reloadPool call, so a
    /// superseded reload skips its post-load steps (dismissal clear, prune
    /// retry, tail backfill, excludeIDs reset) instead of corrupting the
    /// newer call's freshly built pool.
    @State private var reloadSeq = 0
    /// Counts pull-to-refreshes; rotates the TMDB pages (and which favorites
    /// drive "Because you liked") so every refresh brings FRESH titles.
    @State private var refreshNonce = 0
    /// Everything on screen when a refresh started — the rebuilt pool
    /// EXCLUDES these, so refreshing visibly replaces the whole page
    /// (they return only as tail filler when the fresh pool runs thin).
    @State private var excludeIDs: Set<Int> = []
    @Namespace private var posterZoom

    /// The current pool minus dismissed / already-watched, filtered to the
    /// selected media kind.
    /// Grid-mode action history — powers Undo. `saved` = the tap was the
    /// bookmark button; `toggled` = it actually ADDED a bookmark (an
    /// already-bookmarked title stays bookmarked, so undo must not remove it).
    @State private var gridHistory: [(id: Int, saved: Bool, toggled: Bool)] = []

    private var visible: [YourListsView.RecCandidate] {
        // No client-side `filters.passes` here: when filters are active the pool
        // is fetched to match them (discover), and streaming data on a card is
        // too sparse to re-filter against without dropping valid results.
        candidates.filter {
            !dismissed.contains($0.movie.tmdbID)
                && !store.isWatched($0.movie.tmdbID)
                && (suggestTV ? $0.movie.mediaKind == "tv" : $0.movie.mediaKind != "tv")
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .screenHPadding()
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                    .background(Theme.background)
                // Pills sit just outside the screen gutter so they align with
                // the header chrome instead of being double-indented.
                filterPills
                    .padding(.bottom, 6)
                    .background(Theme.background)
                if !importBannerHidden {
                    importBanner
                        .screenHPadding()
                        .padding(.bottom, 4)
                }
                // The helper note is FIXED here — a steady gap below the filter,
                // right above the cards/grid — so it doesn't shift or scroll when
                // you switch between card and grid views.
                if loaded && !visible.isEmpty {
                    modeNote(layout == .grid
                             ? "Tap a poster to rank a \(suggestTV ? "show" : "movie") you've seen"
                             : "Swipe right to bookmark · left to pass · + to rank")
                        .screenHPadding()
                        .padding(.top, 6)
                        .padding(.bottom, 6)
                }
                ScrollViewReader { proxy in
                    // The VStack is essential: the cards layout returns the deck
                    // PLUS a Spacer, and a bare multi-view tuple inside a
                    // ScrollViewReader overlaps instead of stacking — which made
                    // the card balloon past the screen edge. The VStack restores
                    // normal vertical stacking for every layout.
                    VStack(spacing: 0) {
                        content
                    }
                    // Re-tapping the Recs tab jumps the grid/list back to the
                    // top (the cards layout has nothing to scroll).
                    .onChange(of: tabRouter.retap[.swipe]) { _, _ in
                        withAnimation(.snappy) { proxy.scrollTo("recsTop", anchor: .top) }
                    }
                }
            }
            .nativeContentWidth()
            .background(Theme.background)
            .fullScreenCover(item: $logMovie, onDismiss: {
                // Ranked one → it's now Watched; confirm, and offer to open its
                // page. It also drops from the deck (visible filters watched out).
                if store.watchedCount > watchedCountAtRank, let ranked = lastRanked {
                    ToastCenter.shared.showTap("Ranked \(ranked.title) 🎬 · View") {
                        store.cache(ranked)
                        detailMovie = ranked
                    }
                }
            }) { movie in
                LogFlowView(movie: movie)
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
                    .zoomDestination(id: movie.tmdbID, in: posterZoom)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .sheet(isPresented: $showFilterSheet) {
                MovieFilterSheet(
                    filters: $filters,
                    movies: candidates.map(\.movie),
                    sortDescending: .constant(true),
                    sortHighLabel: "", sortLowLabel: "", showSort: false,
                    allOptions: true)   // Swipe filters guide the discovery pool
                .presentationDetents([.medium, .large])
            }
            .task { await load() }
            // A deep link (e.g. "Movies you may have seen") can ask Recs to
            // preselect Movies or TV — honor it whether the tab is new or alive.
            .onAppear { consumeDeepLink() }
            .onChange(of: tabRouter.pendingRecsTV) { _, _ in consumeDeepLink() }
            // Filters drive the pool here — changing them fetches a fresh,
            // matching set (or the automatic pool when cleared).
            .onChange(of: filters) { _, _ in Task { await reloadPool(excludeShown: false) } }
            // Cards swiped in the deck persist to `dismissedRaw` but the deck
            // handles its own advance, so the session `dismissed` set doesn't
            // hear about them. Fold them in when the view rebuilds (kind or
            // layout toggle) — otherwise every swiped card comes back.
            .onChange(of: suggestTV) { _, _ in foldPersistedDismissals() }
            .onChange(of: layout) { _, _ in foldPersistedDismissals() }
        }
    }

    /// Sync the session dismissed set with the persisted one for titles in the
    /// current pool. Called at deck-rebuild moments only, never mid-animation.
    private func foldPersistedDismissals() {
        let persisted = persistedDismissed
        let inPool = candidates.map(\.movie.tmdbID).filter { persisted.contains($0) }
        dismissed.formUnion(inPool)
    }

    /// Honor a deep link into Swipe: it preselects the media kind (Movies/TV).
    /// The card/grid layout is intentionally left as the user's last mode.
    private func consumeDeepLink() {
        if let wantTV = tabRouter.pendingRecsTV {
            tabRouter.pendingRecsTV = nil
            suggestTV = wantTV
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Recs").font(Theme.pageHeader)
                Spacer()
                // Find (deck) vs Rank (grid), labeled so the two modes read at
                // a glance; the big toggle below is the content split
                // (Movies vs TV). Import lives in the dismissible banner and
                // the Feed menu — a third header control crowded this row.
                compactViewToggle
            }
            SegmentedPillControl(
                segments: ["Movies", "TV Shows"],
                selection: Binding(get: { suggestTV ? 1 : 0 },
                                   set: { suggestTV = $0 == 1 }))
        }
    }

    /// Labeled mode toggle, top-right of the header: Find = the swipe deck
    /// (discover something to watch), Rank = the poster grid (tap titles
    /// you've seen to rank them). The user's pick persists across visits
    /// (`swipe.layout` AppStorage).
    private var compactViewToggle: some View {
        HStack(spacing: 2) {
            compactViewSegment(.cards, icon: "rectangle.stack", label: "Find")
            compactViewSegment(.grid, icon: "square.grid.2x2", label: "Rank")
        }
        .padding(3)
        .background(Capsule().fill(Theme.fill))
        // The product tour points its coachmark at this toggle.
        .tourAnchor("recsToggle")
    }

    private func compactViewSegment(_ option: Layout, icon: String, label: String) -> some View {
        let on = layout == option
        return Button {
            withAnimation(.snappy) { layout = option }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption.weight(.bold))
                Text(label)
                    .font(.footnote.weight(.semibold))
            }
            .foregroundStyle(on ? Theme.background : Theme.gray)
            .padding(.horizontal, 11)
            .frame(height: 30)
            .background(Capsule().fill(on ? Theme.marquee : .clear))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) view\(on ? ", selected" : "")")
    }

    /// The quick filter pills (with the leading filter icon). Lives OUTSIDE the
    /// header's screen gutter — the bar self-insets, so wrapping it in
    /// screenHPadding too would double-indent the pills. No negative padding:
    /// that makes this greedy horizontal scroll report a width wider than the
    /// screen and shoves the whole view off both edges.
    private var filterPills: some View {
        MovieFilterBar(filters: $filters, movies: candidates.map(\.movie),
                       onFilterTap: { showFilterSheet = true }, allOptions: true)
    }

    /// Dismissible nudge to bring a full history over — same look as the import
    /// banner elsewhere.
    private var importBanner: some View {
        Button { showImport = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "square.and.arrow.down")
                    .font(.title3).foregroundStyle(Theme.marquee)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import your history")
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                    Text("Bring your ratings from Letterboxd, IMDb, or Netflix")
                        .font(.caption).foregroundStyle(Theme.gray)
                        .fixedSize(horizontal: false, vertical: true)
                    ImportSourceLogos().padding(.top, 2)
                }
                Spacer(minLength: 18)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .buttonStyle(.plain)
        .floatingCard(cornerRadius: 16)
        .overlay(alignment: .topTrailing) {
            Button {
                Haptics.tap()
                withAnimation { importBannerHidden = true }
                ToastCenter.shared.show("You can import anytime from the menu on your Feed")
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Theme.gray)
                    .padding(10)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss import suggestion")
        }
        .padding(.top, 6)
    }

    /// A small instructional note above the grid/deck, adapting to the toggle.
    private func modeNote(_ text: String) -> some View {
        Label(text, systemImage: "hand.tap")
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.gray)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            // Shaped skeleton, matching the active layout — every sibling tab
            // shows one while loading (DESIGN.md: "a skeleton, not a blank"),
            // and Recs was the lone bare-spinner holdout.
            loadingSkeleton
        } else if visible.isEmpty {
            emptyState
        } else {
            switch layout {
            case .grid:
                ScrollView {
                    SuggestionGrid(
                        movies: visible.map(\.movie),
                        onRank: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                        onSave: { movie in
                            // A bookmark HANDLES the tile: it leaves the grid
                            // (same as card mode) so the page always shows
                            // what's still undecided. Undo brings it back.
                            // Already bookmarked? Keep it that way — toggling
                            // here would silently REMOVE it from Want to Watch.
                            recordDismiss(movie.tmdbID)
                            let adding = !store.isOnWatchlist(movie.tmdbID)
                            gridHistory.append((movie.tmdbID, true, adding))
                            if adding { Task { await store.toggleWatchlist(movie: movie) } }
                            withAnimation(.snappy) { _ = dismissed.insert(movie.tmdbID) }
                        },
                        onDismiss: { movie in
                            recordDismiss(movie.tmdbID)
                            gridHistory.append((movie.tmdbID, false, false))
                            Task { await SupabaseService.shared.passRec(movie.tmdbID) }
                            withAnimation(.snappy) { _ = dismissed.insert(movie.tmdbID) }
                        }
                    )
                    .screenHPadding()
                    .padding(.top, 2)
                    .id("recsTop")
                }
                // Pull down to rebuild the whole pool with fresh picks.
                .refreshable { await reloadPool() }
                // Undo the last bookmark/pass — the tile springs back.
                .overlay(alignment: .bottom) {
                    if !gridHistory.isEmpty {
                        Button {
                            undoGridAction()
                        } label: {
                            Label("Undo", systemImage: "arrow.uturn.backward")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                                .background(Capsule().fill(Theme.surface2))
                                .overlay(Capsule().strokeBorder(Theme.hairline))
                                .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .padding(.bottom, 14)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
            case .cards:
                RecCardDeck(
                    candidates: visible,
                    onOpen: { store.cache($0); detailMovie = $0 },
                    onLog: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                    onSave: { m in
                        recordDismiss(m.tmdbID)
                        Task { await store.setWatchlist(movie: m, saved: true) }
                    },
                    onUnsave: { m in
                        Task { await store.setWatchlist(movie: m, saved: false) }
                    },
                    onPass: { m in
                        recordDismiss(m.tmdbID)
                        Task { await SupabaseService.shared.passRec(m.tmdbID) }
                    },
                    onUndo: { m in
                        unrecordDismiss(m.tmdbID)
                        Task { await SupabaseService.shared.unpassRec(m.tmdbID) }
                    },
                    onRefresh: { Task { await reloadPool() } },
                    showRank: true,
                    onRank: { watchedCountAtRank = store.watchedCount; lastRanked = $0; logMovie = $0 },
                    richDetail: true,
                    bookmarkCounts: bookmarkCounts
                )
                // Reset the deck's position when switching Movies ↔ TV or when
                // the pool reloads (filters changed / refreshed).
                .id("\(suggestTV)-\(poolVersion)")
                // Match the app's standard screen gutter so the deck lines up
                // with the grid/list views and doesn't run to the screen edge.
                .screenHPadding()
                Spacer(minLength: 0)
            }
        }
    }

    /// Loading placeholder shaped like the content it becomes: a big card
    /// with control circles in deck mode, a poster grid in grid mode.
    @ViewBuilder
    private var loadingSkeleton: some View {
        switch layout {
        case .cards:
            VStack(spacing: 18) {
                RoundedRectangle(cornerRadius: 22)
                    .fill(Theme.surface2)
                    .overlay(RoundedRectangle(cornerRadius: 22)
                        .fill(Theme.fill).modifier(SkeletonPulse()))
                    .frame(maxHeight: .infinity)
                HStack(spacing: 28) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(Theme.fill)
                            .frame(width: 54, height: 54)
                            .modifier(SkeletonPulse())
                    }
                }
                .padding(.bottom, 10)
            }
            .screenHPadding()
        case .grid:
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 12)],
                          spacing: 14) {
                    ForEach(0..<9, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Theme.surface2)
                            .overlay(RoundedRectangle(cornerRadius: 12)
                                .fill(Theme.fill).modifier(SkeletonPulse()))
                            .aspectRatio(2 / 3, contentMode: .fit)
                    }
                }
                .screenHPadding()
                .padding(.top, 8)
            }
            .allowsHitTesting(false)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle" : "sparkles")
                .font(.largeTitle).foregroundStyle(Theme.gray)
            if filters.isActive {
                Text("Nothing matches these filters")
                    .font(.subheadline.weight(.bold))
                Text("Try loosening a filter \(suggestTV ? "or switching to Movies" : "or switching to TV Shows").")
                    .font(.caption).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                Button {
                    Haptics.tap()
                    filters = MovieFilters()
                } label: {
                    Text("Clear filters").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain).padding(.top, 2)
            } else {
                Text(suggestTV ? "Fresh shows are on the way" : "Fresh picks are on the way")
                    .font(.subheadline.weight(.bold))
                Text("Rank a few titles and Cini dials in your taste — your personalized deck shows up right here.")
                    .font(.caption).foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center).padding(.horizontal, 40)
                // A reload escape hatch — if this is empty because a fetch failed
                // (offline), Try again recovers without toggling a filter.
                Button {
                    Haptics.tap()
                    Task { await reloadPool() }
                } label: {
                    Text("Try again").font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.marquee)
                }
                .buttonStyle(.plain).padding(.top, 2)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Reload the pool from scratch — used when the filters change (they drive
    /// a different pool on the Swipe page) or on a manual refresh.
    /// Titles passed/saved in Recs before, excluded when (re)building the pool.
    /// `dismissedRaw` keeps INSERTION ORDER (oldest first), so pruning
    /// genuinely drops the oldest dismissals — a Set round-trip made
    /// `suffix()` keep a random subset instead of the most recent.
    private var persistedDismissedOrdered: [Int] {
        dismissedRaw.split(separator: ",").compactMap { Int($0) }
    }
    private var persistedDismissed: Set<Int> {
        Set(persistedDismissedOrdered)
    }
    private func recordDismiss(_ id: Int) {
        var list = persistedDismissedOrdered
        guard !list.contains(id) else { return }
        list.append(id)
        // Bounded: the server-side pass keeps the taste signal permanently;
        // this local list only prevents quick re-shows, and unpruned it grew
        // forever (and was re-parsed per candidate before the hoists above).
        if list.count > 2000 { list = Array(list.suffix(1500)) }
        dismissedRaw = list.map(String.init).joined(separator: ",")
    }
    private func unrecordDismiss(_ id: Int) {
        var list = persistedDismissedOrdered
        guard let index = list.firstIndex(of: id) else { return }
        list.remove(at: index)
        dismissedRaw = list.map(String.init).joined(separator: ",")
    }

    /// Reverse the most recent grid action: the tile returns, and a
    /// bookmark it made is taken back off the watchlist.
    private func undoGridAction() {
        guard let last = gridHistory.popLast() else { return }
        Haptics.tap()
        unrecordDismiss(last.id)
        withAnimation(.snappy) { _ = dismissed.remove(last.id) }
        if last.saved {
            // Only take the bookmark back off if this action actually ADDED it
            // — undoing a tap on an already-bookmarked title keeps the save.
            // setWatchlist waits out any in-flight toggle, so an instant Undo
            // can't race the save and silently no-op.
            if last.toggled,
               let movie = store.movie(last.id) ?? candidates.first(where: { $0.movie.tmdbID == last.id })?.movie {
                Task { await store.setWatchlist(movie: movie, saved: false) }
            }
        } else {
            Task { await SupabaseService.shared.unpassRec(last.id) }
        }
    }

    /// `excludeShown` = pull-to-refresh semantics (replace the page).
    /// Filter changes pass false: a visible title that matches the new
    /// filter should stay, not be banished for having been on screen.
    private func reloadPool(excludeShown: Bool = true) async {
        // A newer reload (e.g. a filter change while a pull-to-refresh is
        // mid-flight) supersedes this one: without the generation check, the
        // older call's backfill appends its pre-refresh unfiltered page onto
        // the newer call's freshly filtered pool.
        reloadSeq += 1
        let myReload = reloadSeq
        // A refresh must REPLACE what's on screen, not re-deal it: remember
        // the visible pool and build the next one without it.
        let previous = visible
        excludeIDs = excludeShown ? Set(previous.map(\.movie.tmdbID)) : []
        // Rotate the sources so the refresh actually brings NEW titles —
        // rebuilding page 1 of the same feeds produced an identical pool.
        refreshNonce += 1
        // Build the new pool WITHOUT tearing the visible grid down first:
        // blanking `candidates`/`loaded` mid refresh-gesture swapped the
        // ScrollView for a spinner and visibly glitched the animation. The
        // old grid stays until the fresh one lands in one assignment.
        let responded = await load(force: true)
        guard myReload == reloadSeq else { return }
        // Session dismissals clear only AFTER the fresh pool lands — clearing
        // them before the fetch resurrected every just-swiped tile for the
        // duration of the network round trip.
        dismissed = []
        gridHistory = []
        // "Refresh recs" must actually GIVE MORE CARDS: a power user can have
        // dismissed everything the pool serves, and a refresh that comes back
        // empty is a dead end. Forget the oldest local dismissals and try
        // once more — the server-side pass signal (taste) is untouched.
        // ONLY when the sources actually answered, though: pruning after an
        // offline refresh would wipe the dismissed list for nothing.
        if responded, visible.isEmpty, !dismissedRaw.isEmpty {
            let recent = persistedDismissedOrdered.suffix(200)
            dismissedRaw = recent.map(String.init).joined(separator: ",")
            _ = await load(force: true)
            guard myReload == reloadSeq else { return }
        }
        // Thin fresh pool (small library, sparse sources)? Backfill the TAIL
        // with what was showing before, so a refresh never strands the user
        // on a near-empty page — the top is still all-new.
        if excludeShown, responded, visible.count < 8 {
            let have = Set(candidates.map(\.movie.tmdbID))
            candidates += previous.filter {
                !have.contains($0.movie.tmdbID) && !store.isWatched($0.movie.tmdbID)
            }
        }
        excludeIDs = []
    }

    /// Returns whether any pool source actually ANSWERED (success, even if
    /// empty) — false means the fetches failed and emptiness proves nothing.
    /// `force` rebuilds even over a live pool (pull-to-refresh).
    @discardableResult
    private func load(force: Bool = false) async -> Bool {
        guard force || candidates.isEmpty else { return true }
        // Filters active → fetch a pool that MATCHES them (discovery). Otherwise
        // the automatic, taste-based pool.
        if filters.isActive { return await loadFiltered() }
        return await loadAutomatic()
    }

    /// A filter-driven pool: TMDB discover for both movies and shows matching the
    /// active filters, so the deck is full of on-target picks.
    private func loadFiltered() async -> Bool {
        loadSeq += 1
        let token = loadSeq
        let page = 1 + (refreshNonce % 5)
        async let moviePool = TMDBService.shared.discover(
            genre: filters.genre, decade: filters.decade,
            maxRuntime: filters.runtime, provider: filters.streamingProvider,
            wantTV: false, page: page)
        async let tvPool = TMDBService.shared.discover(
            genre: filters.genre, decade: filters.decade,
            maxRuntime: filters.runtime, provider: filters.streamingProvider,
            wantTV: true, page: page)
        let movieResults = try? await moviePool
        let tvResults = try? await tvPool
        let responded = movieResults != nil || tvResults != nil
        let pool = (movieResults ?? []) + (tvResults ?? [])
        guard token == loadSeq else { return responded }   // a newer reload superseded this one
        // Total failure (offline refresh/filter change): keep the pool we
        // have instead of replacing the visible grid with an empty state.
        guard responded else { loaded = true; return false }

        var seen = Set<Int>()
        var built: [YourListsView.RecCandidate] = []
        // Parsed ONCE — inside the loop this re-split the whole (unbounded)
        // dismissed string per candidate.
        let dismissed = persistedDismissed
        for movie in pool where movie.posterPath != nil
            && seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID)
            && !dismissed.contains(movie.tmdbID) && !excludeIDs.contains(movie.tmdbID) {
            store.cache(movie)
            built.append(YourListsView.RecCandidate(movie: movie, reason: filterReason()))
        }
        candidates = built
        loaded = true
        poolVersion += 1
        // Counts and enrichment are independent — overlap them so the cards
        // don't wait on the bookmark-count round trip before enriching.
        async let counts = SupabaseService.shared.watchlistCounts(movieIDs: built.map(\.movie.tmdbID))
        await enrich(built.prefix(16).map(\.movie.tmdbID))
        if let counts = await counts { bookmarkCounts = counts }
        guard token == loadSeq else { return responded }
        candidates = candidates.map {
            YourListsView.RecCandidate(movie: store.movie($0.movie.tmdbID) ?? $0.movie, reason: $0.reason)
        }
        return responded
    }

    /// A short "why this is here" line for a filtered pool.
    private func filterReason() -> String {
        if let g = filters.genre { return "\(g) pick" }
        if let p = filters.streamingProvider { return "On \(p)" }
        if let d = filters.decade { return "From the \(d)s" }
        return "Matches your filters"
    }

    private func loadAutomatic() async -> Bool {
        loadSeq += 1
        let token = loadSeq
        // The user's top few favorites (highest-scored across movies + TV), so
        // "Because you liked X" can reason across their taste, not just their #1.
        // On refresh, pick a different trio from the top shelf so the
        // "Because you liked" lanes change too.
        let topShelf = store.watchedItems.sorted { $0.score > $1.score }.prefix(8)
        let favorites = refreshNonce == 0
            ? Array(topShelf.prefix(3))
            : Array(topShelf.shuffled().prefix(3))
        let page = 1 + (refreshNonce % 5)
        async let friendRecsTask = SupabaseService.shared.recsForUser()
        async let trendingTask = TMDBService.shared.trending(page: page)
        async let popularTask = TMDBService.shared.popular(page: page)
        let similarByFavorite = await similarToFavorites(favorites)

        var pending: [(id: Int, reason: String)] = []
        var seen = Set<Int>()
        // Did ANY source answer? False = every fetch failed, so an empty
        // pool proves nothing (and must not trigger the dismissal prune).
        var responded = !similarByFavorite.isEmpty

        if let friendRecs = try? await friendRecsTask {
            responded = true
            let rows = (try? await SupabaseService.shared.movies(ids: friendRecs.map(\.movieId))) ?? []
            for row in rows { store.cache(row.asMovie) }
            for rec in friendRecs where seen.insert(rec.movieId).inserted {
                let who = rec.topFriendUsername.map { "@\($0)" } ?? "friends"
                pending.append((rec.movieId, rec.friendCount > 1
                    ? "Loved by \(who) + \(rec.friendCount - 1) more"
                    : "Loved by \(who)"))
            }
        }
        // "Because you liked X" — attributed to each favorite the rec is similar
        // to, so the deck cites several of your favorites instead of only your #1.
        for fav in similarByFavorite {
            for movie in fav.movies.prefix(5)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Because you liked \(fav.title)"))
            }
        }
        if let trending = try? await trendingTask {
            responded = true
            for movie in trending
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Trending this week"))
            }
        }
        if let popular = try? await popularTask {
            responded = true
            for movie in popular
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Popular right now"))
            }
        }

        guard token == loadSeq else { return responded }   // a newer reload superseded this one
        // Every source failed (offline pull-to-refresh): keep the current
        // pool — an empty `pending` proves nothing about the user's recs.
        guard responded else { loaded = true; return false }
        let dismissed = persistedDismissed
        candidates = pending.compactMap { candidate in
            guard !dismissed.contains(candidate.id),
                  !excludeIDs.contains(candidate.id) else { return nil }
            return store.movie(candidate.id).map {
                YourListsView.RecCandidate(movie: $0, reason: candidate.reason)
            }
        }
        loaded = true
        poolVersion += 1

        // How many people have each title bookmarked — social proof on the
        // cards. Overlapped with enrichment below.
        async let counts = SupabaseService.shared.watchlistCounts(movieIDs: pending.map(\.id))

        // Fill in runtime, streaming, and a plot summary for the richer cards
        // (and so the genre/streaming filters have something to match) — in the
        // background so the deck shows immediately.
        await enrich(pending.prefix(16).map(\.id))
        if let counts = await counts { bookmarkCounts = counts }
        guard token == loadSeq else { return responded }
        candidates = candidates.map {
            YourListsView.RecCandidate(movie: store.movie($0.movie.tmdbID) ?? $0.movie, reason: $0.reason)
        }
        return responded
    }

    /// At most six detail fetches in flight (polite to TMDB).
    private func enrich(_ ids: [Int]) async {
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            var remaining = ids[...]
            for _ in 0..<min(6, remaining.count) {
                let id = remaining.removeFirst()
                group.addTask { await store.enrich(id) }
            }
            while await group.next() != nil {
                if let id = remaining.popFirst() { group.addTask { await store.enrich(id) } }
            }
        }
    }

    /// For each favorite (by ranked order), the TMDB "more like this" titles,
    /// paired with the favorite's title for the rec card's reason line. Fetched
    /// in parallel so adding favorites doesn't slow the deck.
    private func similarToFavorites(_ favs: [ScoredItem<Int>]) async -> [(title: String, movies: [Movie])] {
        // Resolve titles on the main actor first; the network calls capture only ids.
        let titled: [(id: Int, title: String)] = favs.compactMap { fav in
            store.movie(fav.id).map { (fav.id, $0.title) }
        }
        let byID = await withTaskGroup(of: (Int, [Movie])?.self) { group in
            for fav in titled {
                let id = fav.id
                group.addTask {
                    guard let sim = try? await TMDBService.shared.similar(to: id), !sim.isEmpty
                    else { return nil }
                    return (id, sim)
                }
            }
            var acc: [Int: [Movie]] = [:]
            for await result in group { if let result { acc[result.0] = result.1 } }
            return acc
        }
        // Preserve the favorites' ranked order (top favorite leads the deck).
        return titled.compactMap { fav in
            byID[fav.id].map { (title: fav.title, movies: $0) }
        }
    }
}
