import SwiftUI
import RankingEngine

/// "MY LISTS": category switcher, Watched/Want to Watch/Watching/Friend Recs
/// sub-tabs, filter pills, sort control, and ranked rows.
struct YourListsView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @Environment(AppSession.self) private var session
    @State private var importQueue = ImportQueue.shared

    @State private var category: MediaCategory = .movies
    @State private var subTab: SubTab = .watched
    // Sort + filters persist across launches — the list stays the way
    // the user left it.
    @AppStorage("lists.sortDescending") private var sortDescending = true
    @AppStorage("lists.genreFilter") private var genreFilter: String?
    @AppStorage("lists.decadeFilter") private var decadeFilter: Int?
    @AppStorage("lists.runtimeFilter") private var runtimeFilter: Int?   // max minutes
    @AppStorage("lists.streamingProvider") private var streamingProviderFilter: String?
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var watchingRows: [WatchingRow] = []
    @State private var watchingLoaded = false
    @State private var showWatchingInfo = false
    @State private var predicted: [Int: Double] = [:]
    @State private var showListSearch = false
    @State private var showFilterSheet = false
    @State private var listQuery = ""
    @State private var reorderMode = false
    @State private var pendingDeleteRating: Movie?
    @State private var showAllPending = false
    @State private var showImport = false
    @State private var directRecs: [DirectRecRow] = []
    @State private var directRecsLoaded = false
    // Friend Recs default to the swipe-card view (CIN-36); List stays available.
    // A friend rec being passed — drives the optional "tell them why" sheet.
    @State private var passingRec: DirectRecRow?
    @State private var showRecPicker = false
    // Custom lists live as tabs beside the defaults; defaults can be
    // hidden from Edit Lists (Watched/Want to Watch always stay). The lists
    // themselves are read straight off the shared store (no parallel @State
    // copy) so a list created/renamed/deleted from any surface — a movie page,
    // Chat, the Edit Lists sheet — shows here without a manual re-sync.
    @AppStorage("lists.hiddenTabs") private var hiddenTabsRaw = ""
    @State private var selectedListID: UUID?
    @State private var customListMovies: [Movie] = []
    @State private var customListLoaded = false
    /// The list id `customListMovies` currently holds — so a listsRevision-only
    /// refresh refetches in place instead of clearing to a skeleton.
    @State private var loadedListID: UUID?
    @State private var showEditLists = false
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var showDeleteListConfirm = false

    /// The custom list currently open as a tab, if any.
    private var selectedList: CustomList? {
        selectedListID.flatMap { id in store.customLists.first { $0.id == id } }
    }

    private var hiddenTabs: Set<String> {
        Set(hiddenTabsRaw.split(separator: ",").map(String.init))
    }

    private var visibleDefaultTabs: [SubTab] {
        SubTab.allCases.filter { tab in
            switch tab {
            // Currently Watching is a TV-only concept (you binge shows, not
            // movies) — hide it under the Movies category.
            case .watching: return category == .tvShows
            case .friendRecs: return !hiddenTabs.contains(tab.rawValue)
            default: return true
            }
        }
    }

    struct RecCandidate: Identifiable, Hashable {
        let movie: Movie
        let reason: String
        var id: Int { movie.tmdbID }
    }

    enum SubTab: String, CaseIterable {
        case watched = "Watched"
        case watchlist = "Want to Watch"
        case watching = "Watching"
        case friendRecs = "Friend Recs"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                categoryRow
                subTabs
                // Filters are first-class on EVERY personal list — the
                // defaults and your own lists alike.
                if (selectedListID != nil || subTab != .friendRecs), !reorderMode {
                    filterBar
                    if showListSearch { listSearchField }
                    sortSearchRow
                }
                ScrollViewReader { proxy in
                    listContent
                        // Let the zero-height scroll-to-top anchor actually be
                        // zero. Without this, SwiftUI clamps every row (the
                        // anchor included) to the ~44pt default minimum, leaving
                        // a phantom gap above the first card. Real rows are taller
                        // than their content min, so they're unaffected.
                        .environment(\.defaultMinListRowHeight, 0)
                        // Re-tapping the Your Lists tab jumps back to the top.
                        .onChange(of: tabRouter.retap[.lists]) { _, _ in
                            withAnimation(.snappy) { proxy.scrollTo("listsTop", anchor: .top) }
                        }
                }
            }
            .nativeContentWidth()
            .background(Theme.background)
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .sheet(isPresented: $showFilterSheet) {
                MovieFilterSheet(
                    filters: filtersBinding,
                    movies: Array(store.movies.values),
                    sortDescending: $sortDescending,
                    sortHighLabel: sortHighLabel,
                    sortLowLabel: sortLowLabel,
                    showSort: false)   // sort is its own row (Beli-style), not here
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showRecPicker) {
                SendRecMoviePicker()
            }
            .task {
                // Refresh the shared store's lists; it keeps the prior set on a
                // transient failure, so the tabs never blank out.
                await store.refreshCustomLists()
            }
            .task(id: subTab) {
                if subTab == .watching, let me = SupabaseService.shared.currentUserID {
                    watchingRows = await SupabaseService.shared.watching(for: me)
                    watchingLoaded = true
                }
            }
            .alert("Currently Watching", isPresented: $showWatchingInfo) {
                Button("Got it", role: .cancel) {}
            } message: {
                Text("A show lands here when you tap “I'm watching this” on its page, and leaves when you rank it or tap Remove. Friends can see what you're watching.")
            }
            .sheet(isPresented: $showEditLists, onDismiss: {
                Task { await store.refreshCustomLists() }
                if selectedListID != nil && !store.customLists.contains(where: { $0.id == selectedListID }) {
                    selectedListID = nil
                }
                if !visibleDefaultTabs.contains(subTab) { subTab = .watched }
            }) {
                EditListsSheet()
                    .presentationDetents([.medium, .large])
            }
            .alert("New List", isPresented: $showNewList) {
                TextField("Name (e.g. Best heist movies)", text: $newListName)
                Button("Create") {
                    let name = newListName.trimmingCharacters(in: .whitespaces)
                    newListName = ""
                    guard !name.isEmpty else { return }
                    Task {
                        // Born under the active category: a list holds one
                        // media type and lives on that filter only. Routed
                        // through the store so every surface sees it.
                        if let list = await store.createList(
                            name: name, mediaKind: category.mediaKind) {
                            withAnimation(.snappy) { selectedListID = list.id }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newListName = "" }
            } message: {
                Text("Add movies to it from any movie page with \"Add to List\".")
            }
            // A whole list is hours of curation — deleting one confirms.
            .alert(
                "Delete \"\(selectedList?.name ?? "this list")\"?",
                isPresented: $showDeleteListConfirm
            ) {
                Button("Delete list", role: .destructive) {
                    guard let doomed = selectedList else { return }
                    // Snap back to Watched, then delete through the store so
                    // every surface (tabs, the add-to-list picker) agrees.
                    withAnimation(.snappy) { selectedListID = nil; subTab = .watched }
                    Task { await store.deleteList(doomed.id) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its titles stay on your other lists — only this list goes.")
            }
            .onChange(of: tabRouter.pendingCustomListID) { _, _ in
                consumePendingCustomList()
            }
            // Deep links can arrive while this tab is already alive (.onAppear
            // won't re-fire), so observe the flags too — mirrors the custom-list
            // handling above.
            .onChange(of: tabRouter.pendingListsTab) { _, _ in consumePendingListsTab() }
            .onChange(of: tabRouter.pendingReorder) { _, _ in consumePendingReorder() }
            // Category switch with a list of the OTHER kind selected: its
            // tab just vanished — deselect rather than render a ghost.
            .onChange(of: category) { _, newCategory in
                if let selectedListID,
                   let list = store.customLists.first(where: { $0.id == selectedListID }),
                   list.kind != newCategory.mediaKind {
                    self.selectedListID = nil
                }
                // Watching is TV-only — switching to Movies retires that tab.
                if !visibleDefaultTabs.contains(subTab) { subTab = .watched }
            }
            .onAppear {
                consumePendingCustomList()
                consumePendingListsTab()
                consumePendingReorder()
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
        }
    }

    /// An agent receipt chip can deep-link straight into a custom list —
    /// even one created seconds ago that this tab hasn't fetched yet.
    private func consumePendingCustomList() {
        guard let pending = tabRouter.pendingCustomListID else { return }
        tabRouter.pendingCustomListID = nil
        if let list = store.customLists.first(where: { $0.id == pending }) {
            withAnimation(.snappy) { select(list) }
        } else {
            Task {
                await store.refreshCustomLists()
                if let list = store.customLists.first(where: { $0.id == pending }) {
                    withAnimation(.snappy) { select(list) }
                }
            }
        }
    }

    /// A deep link asked for a specific sub-tab (e.g. the profile's
    /// "Watched (N)" count). Consumed from both onAppear and onChange so it
    /// works whether the tab was just created or is already alive.
    private func consumePendingListsTab() {
        guard let pending = tabRouter.pendingListsTab else { return }
        tabRouter.pendingListsTab = nil
        subTab = pending
        selectedListID = nil
        // A deep link wins over the hide preference.
        if !visibleDefaultTabs.contains(pending) {
            var hidden = hiddenTabs
            hidden.remove(pending.rawValue)
            hiddenTabsRaw = hidden.sorted().joined(separator: ",")
        }
        // Land where the content is: the profile count spans both categories,
        // so "Watched (1)" must never open onto an empty Movies view when the 1
        // is a show. (Only once the store is real — a half-loaded store must
        // not steer the category.)
        if store.isLoaded {
            if pending == .watched, watchedCount(in: category) == 0,
               watchedCount(in: otherCategory) > 0 {
                category = otherCategory
            }
            if pending == .watchlist, watchlistCount(in: category) == 0,
               watchlistCount(in: otherCategory) > 0 {
                category = otherCategory
            }
        }
    }

    /// A deep link asked to reorder the Watched list — same dual-entry pattern.
    private func consumePendingReorder() {
        guard tabRouter.pendingReorder else { return }
        tabRouter.pendingReorder = false
        category = tabRouter.pendingReorderTV ? .tvShows : .movies
        subTab = .watched
        reorderMode = true
        listQuery = ""; showListSearch = false
        genreFilter = nil; decadeFilter = nil
        runtimeFilter = nil; streamingProviderFilter = nil
        sortDescending = true   // drag offsets need canonical order
    }

    /// Selecting a list also lands on its category — a TV list's tab
    /// only exists under TV Shows.
    private func select(_ list: CustomList) {
        category = list.kind == "tv" ? .tvShows : .movies
        selectedListID = list.id
    }

    private var headerShareText: String {
        if let selectedListID,
           let list = store.customLists.first(where: { $0.id == selectedListID }) {
            return listShareText(name: list.name, movies: customListMovies,
                                 listID: list.id, isPrivate: list.isPrivate)
        }
        // Your rankings render on your public web profile — share that (rich
        // preview card + referral) rather than a bare App Store link.
        if let username = session.profile?.username, !username.isEmpty {
            return "My movie & TV rankings live on Cini 🎬\n\(AppLinks.profileLink(username))"
        }
        return "My movie & TV rankings live on Cini 🎬\n\(AppLinks.appStore)"
    }

    /// Plain HStack with generous tap targets — the old overlay-based
    /// layout made the ellipsis flaky to hit.
    /// Import-your-history button: icon + "Import" label — the same prominent
    /// action the Swipe page uses, mirrored here.
    private var importButton: some View {
        Button { showImport = true } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.and.arrow.down")
                Text("Import")
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.marquee)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(Theme.fill))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Import your history")
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Lists").font(Theme.pageHeader)
            Spacer()
            importButton
            HStack(spacing: 2) {
                // Sharing a selected custom list shares THAT list.
                ShareLink(item: headerShareText) {
                    Image(systemName: "square.and.arrow.up")
                        .padding(8)
                        .contentShape(Rectangle())
                }
                Menu {
                    Button {
                        showNewList = true
                    } label: {
                        Label("New List", systemImage: "plus")
                    }
                    Button {
                        showEditLists = true
                    } label: {
                        Label("Edit Lists", systemImage: "slider.horizontal.3")
                    }
                    Divider()
                    Button {
                        withAnimation(.snappy) {
                            showListSearch.toggle()
                            if !showListSearch { listQuery = "" }
                        }
                    } label: {
                        Label("Search this list", systemImage: "magnifyingglass")
                    }
                    if subTab == .watched && selectedListID == nil {
                        Button {
                            withAnimation(.snappy) {
                                reorderMode.toggle()
                                if reorderMode {   // reorder works on the full list
                                    listQuery = ""
                                    showListSearch = false
                                    genreFilter = nil; decadeFilter = nil
                                    runtimeFilter = nil; streamingProviderFilter = nil
                                    // Drag offsets map onto the canonical
                                    // order — a reversed list would move
                                    // the wrong rows.
                                    sortDescending = true
                                }
                            }
                        } label: {
                            Label(reorderMode ? "Done reordering" : "Reorder",
                                  systemImage: "arrow.up.arrow.down")
                        }
                    }
                    // Deleting a custom list lives where you're viewing it.
                    if let selectedList {
                        Divider()
                        Button(role: .destructive) {
                            showDeleteListConfirm = true
                        } label: {
                            Label("Delete \"\(selectedList.name)\"", systemImage: "trash")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                }
            }
            .foregroundStyle(Theme.ink)
        }
        // Match the Swipe page: standard screen gutter, 8pt above and a 12pt
        // gap down to the Movies/TV toggle.
        .screenHPadding()
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var categoryRow: some View {
        // Movies / TV Shows as a segmented tab switcher (was a dropdown).
        SegmentedPillControl(
            segments: ["Movies", "TV Shows"],
            selection: Binding(get: { category == .tvShows ? 1 : 0 },
                               set: { category = $0 == 1 ? .tvShows : .movies }))
            .screenHPadding()
    }

    private var subTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(visibleDefaultTabs, id: \.self) { tab in
                    let isOn = subTab == tab && selectedListID == nil
                    Button {
                        withAnimation(.snappy) {
                            subTab = tab
                            selectedListID = nil
                        }
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(isOn ? .bold : .regular))
                                    .foregroundStyle(isOn ? Theme.ink : Theme.gray)
                                // Pending-import count: visible from every
                                // sub-tab so the queue can't be forgotten.
                                if tab == .watched && !pendingEntries.isEmpty {
                                    Text("\(pendingEntries.count)")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Theme.onMarquee)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Theme.marquee))
                                }
                            }
                            Rectangle()
                                .fill(isOn ? Theme.ink : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }

                // Your own lists ride the same row — only the ones that
                // belong to the active category (a list is movies OR
                // shows, never both).
                ForEach(store.customLists.filter { $0.kind == category.mediaKind }) { list in
                    let isOn = selectedListID == list.id
                    Button {
                        withAnimation(.snappy) { selectedListID = list.id }
                    } label: {
                        VStack(spacing: 6) {
                            Text(list.name)
                                .font(.subheadline.weight(isOn ? .bold : .regular))
                                .foregroundStyle(isOn ? Theme.ink : Theme.gray)
                                .lineLimit(1)
                            Rectangle()
                                .fill(isOn ? Theme.ink : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
            }
            .screenHPadding()
        }
        .padding(.top, 10)
    }

    /// Direct recommendations friends sent you — all of them live here, as a
    /// Friend recs scoped to the active category — a TV rec must not show under
    /// Movies (and vice versa), matching every other sub-tab.
    private var filteredDirectRecs: [DirectRecRow] {
        directRecs.filter { rec in
            guard let movie = rec.movies?.asMovie else { return false }
            // Once you've ranked it, it's no longer a pending rec — drop it the
            // instant you watch it (the server also clears it and tells the friend).
            if store.isWatched(movie.tmdbID) { return false }
            return category.matches(movie)
        }
    }

    /// list (the swipe-card view lives on the Swipe tab now).
    private var friendRecsList: some View {
        friendRecsAsList
        .task {
            directRecs = (try? await SupabaseService.shared.directRecs()) ?? []
            directRecsLoaded = true
            let ids = directRecs.compactMap { $0.movies?.asMovie.tmdbID }
            let map = await SupabaseService.shared.predictedScores(movieIDs: ids)
            predicted.merge(map) { _, new in new }
        }
        // Passing a friend's card → optionally tell them why (CIN-36).
        .sheet(item: $passingRec) { rec in
            PassRecMessageSheet(rec: rec) { message in
                await SupabaseService.shared.passDirectRec(id: rec.id, message: message)
            }
        }
    }

    private var friendRecsAsList: some View {
        List {
            listTopAnchor
            if !directRecsLoaded {
                SearchSkeleton(kind: .titles, rows: 5)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            }
            if filteredDirectRecs.isEmpty && directRecsLoaded {
                VStack(spacing: 10) {
                    Image(systemName: "paperplane").font(.title).foregroundStyle(Theme.gray)
                    Text("No picks from friends yet")
                        .font(.subheadline.weight(.semibold))
                    Text("When a friend recommends a title just for you, it lands right here with their note.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
                    // The fix for an empty inbox is more friends or being
                    // the first to send — hand both over right here.
                    HStack(spacing: 10) {
                        PillButton(title: "Find friends", systemImage: "person.badge.plus") {
                            tabRouter.openMembersSearch = true
                            tabRouter.selection = .search
                        }
                        PillButton(title: "Recommend", systemImage: "paperplane",
                                   style: .outlined) {
                            showRecPicker = true
                        }
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
                .listRowBackground(Theme.background)
            }
            ForEach(filteredDirectRecs) { rec in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AvatarView(url: rec.profiles?.avatarUrl.flatMap(URL.init), size: 28,
                                   name: preferredName(rec.profiles?.displayName, rec.profiles?.username))
                        (Text(firstName(rec.profiles?.displayName, rec.profiles?.username) ?? "friend").bold()
                            + Text(" thinks you'll love this"))
                            .font(.caption)
                        Spacer()
                        Button {
                            let removed = rec
                            withAnimation(.snappy) { directRecs.removeAll { $0.id == rec.id } }
                            Task {
                                do { try await SupabaseService.shared.dismissDirectRec(id: removed.id) }
                                catch {
                                    // Put it back if the dismiss didn't take.
                                    withAnimation(.snappy) { directRecs.append(removed) }
                                    ToastCenter.shared.saveFailed()
                                }
                            }
                        } label: {
                            Image(systemName: "xmark").font(.caption).foregroundStyle(Theme.gray)
                                .padding(8)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Dismiss rec")
                    }
                    if let movie = rec.movies?.asMovie {
                        WatchlistRowView(movie: movie, predicted: predicted[movie.tmdbID]) {
                            logMovie = movie
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.cache(movie)
                            detailMovie = movie
                        }
                        if let note = rec.note {
                            Text("“\(note)”")
                                .font(.subheadline)
                                .italic()
                                .foregroundStyle(Theme.ink.opacity(0.9))
                        }
                    }
                }
                .padding(.vertical, 4)
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
    }

    private var listSearchField: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                TextField("Search your list", text: $listQuery)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !listQuery.isEmpty {
                    Button {
                        listQuery = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            // "Close" dismisses the field (Beli-style).
            Button("Close") {
                withAnimation(.snappy) { showListSearch = false; listQuery = "" }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Theme.marquee)
            .buttonStyle(.plain)
        }
        .screenHPadding()
        .padding(.bottom, 4)
    }

    private var hasActiveFilters: Bool {
        genreFilter != nil || decadeFilter != nil || runtimeFilter != nil
            || streamingProviderFilter != nil
    }

    /// The persisted filter fields exposed as one shared MovieFilters.
    private var filtersBinding: Binding<MovieFilters> {
        Binding(
            get: {
                MovieFilters(genre: genreFilter, decade: decadeFilter,
                             runtime: runtimeFilter,
                             streamingProvider: streamingProviderFilter)
            },
            set: { filters in
                genreFilter = filters.genre
                decadeFilter = filters.decade
                runtimeFilter = filters.runtime
                streamingProviderFilter = filters.streamingProvider
            }
        )
    }

    /// Whether the Highest/Lowest sort applies to the current list (it lives
    /// inside the filter sheet that the filter icon opens).
    private var showsSortControl: Bool {
        selectedListID == nil && (subTab == .watched || subTab == .watchlist)
    }
    private var sortHighLabel: String { subTab == .watched ? "Highest score" : "Newest" }
    private var sortLowLabel: String { subTab == .watched ? "Lowest score" : "Oldest" }

    /// Row 1 — the filter icon inline at the head of the quick filter pills
    /// (Streaming · Genre · Runtime · Decade); the icon opens the full sheet.
    private var filterBar: some View {
        MovieFilterBar(filters: filtersBinding,
                       movies: Array(store.movies.values),
                       onFilterTap: { showFilterSheet = true })
    }

    /// Row 2 (Beli-style) — sort on the left, a search toggle on the right.
    private var sortSearchRow: some View {
        HStack {
            if showsSortControl { sortMenu } else { Spacer().frame(height: 1) }
            Spacer()
            Button {
                withAnimation(.snappy) {
                    showListSearch.toggle()
                    if !showListSearch { listQuery = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(showListSearch ? Theme.marquee : Theme.ink)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Search this list")
        }
        .screenHPadding()
        .padding(.bottom, 6)
    }

    /// Score (watched) or Date added — the metric the list is sorted on.
    private var sortMetricLabel: String { subTab == .watched ? "Score" : "Date added" }

    /// Tappable sort control: shows the metric with up/down arrows; the menu
    /// flips between high→low (or newest→oldest).
    private var sortMenu: some View {
        Menu {
            Button { sortDescending = true } label: {
                Label(sortHighLabel, systemImage: sortDescending ? "checkmark" : "arrow.down")
            }
            Button { sortDescending = false } label: {
                Label(sortLowLabel, systemImage: sortDescending ? "arrow.up" : "checkmark")
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.arrow.down").font(.caption.weight(.bold))
                Text(sortMetricLabel).font(.subheadline.weight(.bold))
            }
            .foregroundStyle(Theme.marquee)
        }
    }

    // MARK: - Content

    /// A zero-height first row each List carries so re-tapping the tab can
    /// scroll back to the top regardless of which list is showing.
    private var listTopAnchor: some View {
        Color.clear
            .frame(height: 0)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
            // Zero insets so the anchor truly takes no space — default row
            // insets would otherwise leave a ~22pt gap above the first card.
            .listRowInsets(EdgeInsets())
            .id("listsTop")
    }

    @ViewBuilder
    private var listContent: some View {
        if selectedListID != nil {
            customListContent
        } else {
            switch subTab {
            case .watched: watchedList
            case .watchlist: watchlistList
            case .watching: watchingList
            case .friendRecs: friendRecsList
            }
        }
    }

    /// Custom lists respect the same filter pills and search as every
    /// other personal list.
    private var filteredCustomList: [Movie] {
        let query = listQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return customListMovies.filter { movie in
            guard passesFilters(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    /// One of the user's own lists, inline — same rows, swipe to remove.
    private var customListContent: some View {
        List {
            listTopAnchor
            if !customListLoaded {
                ListSkeleton(rows: 6)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            } else if customListMovies.isEmpty {
                Text("This list is a blank canvas — open any movie or show and tap Add to List to start filling it.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            } else if filteredCustomList.isEmpty {
                Text("Nothing matches these filters — loosen one.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            ForEach(filteredCustomList) { movie in
                WatchlistRowView(movie: movie,
                                 predicted: store.predictedScores[movie.tmdbID]) {
                    logMovie = movie
                }
                .contentShape(Rectangle())
                .onTapGesture { detailMovie = movie }
                .listRowBackground(Theme.background)
            }
            .onDelete { offsets in
                guard let listID = selectedListID else { return }
                // Offsets index the FILTERED view — map to titles, then
                // remove by id from the source array.
                let filtered = filteredCustomList
                let doomed = offsets.compactMap { filtered.indices.contains($0) ? filtered[$0] : nil }
                let doomedIDs = Set(doomed.map(\.tmdbID))
                customListMovies.removeAll { doomedIDs.contains($0.tmdbID) }
                Task {
                    // Through the store so listsRevision bumps and other
                    // surfaces refresh (it also toasts on failure).
                    var failed = false
                    for movie in doomed {
                        if !(await store.removeFromList(listID, movieID: movie.tmdbID)) { failed = true }
                    }
                    // Reconcile from the server so a failed remove can't
                    // leave a title that reappears on next open.
                    if failed {
                        let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
                        customListMovies = ids.compactMap { store.movie($0) }
                    } else {
                        // Offer Undo — consistent with Want to Watch / watched.
                        let label = doomed.count == 1
                            ? "Removed \(doomed[0].title)" : "Removed \(doomed.count) titles"
                        ToastCenter.shared.showUndo(label) {
                            Task {
                                for movie in doomed { await store.addToList(listID, movie: movie) }
                                let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
                                customListMovies = ids.compactMap { store.movie($0) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        // Re-keyed on listsRevision too, so adding a title from a movie page or
        // Chat refreshes the open list tab instead of leaving it stale.
        .task(id: "\(selectedListID?.uuidString ?? "none")#\(store.listsRevision)") {
            guard let listID = selectedListID else { return }
            // Only clear/skeleton when the list itself changed. A listsRevision
            // bump (a title added from elsewhere) refetches in place, so the
            // open list updates without flashing a skeleton over its rows.
            if loadedListID != listID {
                customListMovies = []
                customListLoaded = false
            }
            let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
            let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.tmdbId, $0.asMovie) })
            customListMovies = ids.compactMap { byID[$0] ?? store.movie($0) }
            for movie in customListMovies { store.cache(movie) }
            customListLoaded = true
            loadedListID = listID
        }
    }

    /// Category check + the shared five-filter predicate.
    private func passesFilters(_ movie: Movie) -> Bool {
        guard category.matches(movie) else { return false }
        return filtersBinding.wrappedValue.passes(movie)
    }

    private var filteredWatched: [ScoredItem<Int>] {
        // Reorder mode shows the EXACT kind-scoped list moveRanked indexes —
        // unfiltered and in canonical order. Any extra/missing row (a search
        // filter, or an other-kind title whose movie row hasn't cached) would
        // shift every drag offset below it and move the WRONG title.
        if reorderMode {
            return store.lists[category.mediaKind]?.scoredItems ?? []
        }
        let items = sortDescending ? store.watchedItems : store.watchedItems.reversed()
        let query = listQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard let movie = store.movie(item.id) else { return true }
            guard passesFilters(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    /// Imported titles waiting to be ranked — Letterboxd stars are never
    /// copied, so everything from an import sits here until it goes
    /// through head-to-head ranking (favorites first). Lives at the top of
    /// Watched as "Pending"; the goal is to rank it down to zero, at which
    /// point the section disappears.
    private var pendingEntries: [ImportQueue.Entry] {
        // Scope to the current category — Movies and TV are equal-but-separate,
        // so the Pending section (and its count badge) inside a category-scoped
        // Watched list must never mix the two. TV ids are negative.
        importQueue.entries.filter {
            !store.isWatched($0.movieID) && ((category == .tvShows) == ($0.movieID < 0))
        }
    }

    @ViewBuilder
    private var pendingSection: some View {
        HStack(spacing: 8) {
            Text("Pending").font(.headline)
            Text("\(pendingEntries.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.onMarquee)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Capsule().fill(Theme.marquee))
            Spacer()
            Text("Ranked \(importQueue.rankedFromImport) of \(importQueue.totalImported)")
                .font(.caption)
                .foregroundStyle(Theme.gray)
        }
        .listRowBackground(Theme.background)
        .listRowSeparator(.hidden)
        Text("From your import, favorites first — rank or dismiss them all to clear this section.")
            .font(.caption)
            .foregroundStyle(Theme.gray)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
        ForEach(pendingEntries.prefix(showAllPending ? 500 : 3)) { entry in
            let movie = store.movie(entry.movieID)
                ?? Movie(tmdbID: entry.movieID,
                         mediaKind: entry.movieID < 0 ? "tv" : "movie",
                         title: entry.title,
                         releaseYear: entry.year, posterPath: nil, backdropPath: nil,
                         genres: [], certification: nil, runtimeMinutes: nil,
                         director: nil, overview: nil)
            MovieSuggestionRow(
                movie: movie,
                onRank: { logMovie = movie },
                onOpen: { detailMovie = movie },
                onDismiss: { withAnimation(.snappy) { importQueue.dismiss(entry.movieID) } }
            )
            .task { await store.enrich(entry.movieID) }
            .listRowBackground(Theme.background)
        }
        if pendingEntries.count > 3 {
            Button {
                withAnimation(.snappy) { showAllPending.toggle() }
            } label: {
                Text(showAllPending ? "Show fewer" : "See all \(pendingEntries.count)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)
        }
        if !store.watchedItems.isEmpty {
            Text("RANKED")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.5)
                .foregroundStyle(Theme.gray)
                .padding(.top, 8)
                .listRowBackground(Theme.background)
                .listRowSeparator(.hidden)
        }
    }

    private var watchedList: some View {
        List {
            listTopAnchor
            // Discovery lives in the zero state now (the "you may have seen" bar
            // was removed to declutter a populated list).
            if !pendingEntries.isEmpty && !reorderMode
                && listQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                pendingSection
            }
            if reorderMode {
                Text("Drag to reorder — scores update automatically")
                    .font(.caption)
                    .foregroundStyle(Theme.marquee)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            ForEach(filteredWatched, id: \.id) { item in
                if let movie = store.movie(item.id) {
                    WatchedRowView(rank: item.rank, movie: movie, score: item.score)
                        .contentShape(Rectangle())
                        .onTapGesture { if !reorderMode { detailMovie = movie } }
                        .listRowBackground(Theme.background)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                pendingDeleteRating = movie
                            } label: { Label("Delete", systemImage: "trash") }
                            Button {
                                Haptics.tap()
                                logMovie = movie
                            } label: { Label("Rank again", systemImage: "arrow.2.squarepath") }
                            .tint(Theme.marquee)
                        }
                }
            }
            .onMove { from, to in
                Task { await store.moveRanked(kind: category.mediaKind, fromOffsets: from, toOffset: to) }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(reorderMode ? .active : .inactive))
        .alert("Delete this rating?",
               isPresented: Binding(get: { pendingDeleteRating != nil },
                                    set: { if !$0 { pendingDeleteRating = nil } }),
               presenting: pendingDeleteRating) { movie in
            Button("Delete rating", role: .destructive) {
                // removeRanking surfaces its own saveFailed() toast on error.
                Task { await store.removeRanking(movieID: movie.tmdbID) }
                pendingDeleteRating = nil
            }
            Button("Cancel", role: .cancel) { pendingDeleteRating = nil }
        } message: { movie in
            Text("“\(movie.title)” will be removed from your ranking. This can't be undone.")
        }
        .overlay {
            if store.watchedItems.isEmpty && pendingEntries.isEmpty {
                // Same discovery entry point as the bar up top, so the zero
                // state still offers it — swipe through Recs and + to rank.
                emptyList("Rank a few you've already seen and your list starts filling in.",
                          actionTitle: "\(category == .movies ? "Movies" : "Shows") you may have seen",
                          actionIcon: "rectangle.stack") {
                    tabRouter.pendingRecsTV = (category == .tvShows)
                    // Respect the user's last card/grid mode — don't force one.
                    tabRouter.selection = .swipe
                }
            } else if filteredWatched.isEmpty, pendingEntries.isEmpty,
                      watchedCount(in: otherCategory) > 0 {
                // The count on the profile spans both categories — never
                // open onto a blank list without saying where they are.
                emptyList(categoryHiddenMessage(count: watchedCount(in: otherCategory)),
                          actionTitle: "Show \(otherCategory.title)",
                          actionIcon: otherCategory.icon) {
                    withAnimation(.snappy) { category = otherCategory }
                }
            }
        }
    }

    private var otherCategory: MediaCategory {
        category == .movies ? .tvShows : .movies
    }

    private func categoryHiddenMessage(count: Int) -> String {
        "Nothing under \(category.title) — \(count == 1 ? "your 1 title is" : "your \(count) titles are") filed under \(otherCategory.title)."
    }

    private func watchedCount(in target: MediaCategory) -> Int {
        var count = 0
        for item in store.watchedItems {
            if let movie = store.movie(item.id), target.matches(movie) { count += 1 }
        }
        return count
    }

    private func watchlistCount(in target: MediaCategory) -> Int {
        var count = 0
        for item in store.watchlist {
            if let movie = store.movie(item.movieID), target.matches(movie) { count += 1 }
        }
        return count
    }

    /// Want to Watch respects the same sort toggle (date added), search
    /// query, and filter pills as Watched.
    private var filteredWatchlist: [WatchlistItem] {
        let items = sortDescending ? store.watchlist : store.watchlist.reversed()
        let query = listQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard let movie = store.movie(item.movieID) else { return true }
            guard passesFilters(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    /// "Watching" — shows you've marked yourself mid-binge on. An (i) explains
    /// how a title lands here; swipe to stop.
    private var watchingList: some View {
        List {
            listTopAnchor
            Button { showWatchingInfo = true } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                    Text("How shows end up here")
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            .listRowBackground(Theme.background)
            .listRowSeparator(.hidden)

            ForEach(watchingRows) { row in
                HStack(spacing: 12) {
                    PosterView(url: watchingPoster(row.posterPath), width: 46)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(row.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink).lineLimit(2)
                        if let label = episodeLabel(season: row.season, episode: row.episode) {
                            Text(label).font(.caption).foregroundStyle(Theme.marquee)
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
                .onTapGesture { openShow(row.showId) }
                .listRowBackground(Theme.background)
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        let removed = row
                        withAnimation { watchingRows.removeAll { $0.showId == row.showId } }
                        Task {
                            do { try await SupabaseService.shared.clearShowProgress(showID: removed.showId) }
                            catch {
                                withAnimation { watchingRows.append(removed) }
                                ToastCenter.shared.saveFailed()
                            }
                        }
                    } label: { Label("Remove", systemImage: "xmark.circle") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if watchingLoaded && watchingRows.isEmpty {
                emptyList("Track what you're in the middle of — tap “I'm watching this” on any show to follow your progress here.",
                          actionTitle: "Find a show") {
                    tabRouter.pendingSearchBrowse = .trending
                    tabRouter.selection = .search
                }
            }
        }
    }

    private func watchingPoster(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http") { return URL(string: path) }
        return URL(string: "https://image.tmdb.org/t/p/w342\(path)")
    }

    private func openShow(_ showID: Int) {
        Task {
            if let movie = try? await TMDBService.shared.details(for: showID) {
                store.cache(movie)
                detailMovie = movie
            }
        }
    }

    private var watchlistList: some View {
        List {
            listTopAnchor
            // "In theaters" shortcut — the saved MOVIES that are playing now or
            // coming soon, with tickets/showtimes. Only for the Movies category
            // (TV has no theatrical showtimes) and only once something's saved.
            if category == .movies, !filteredWatchlist.isEmpty {
                NavigationLink {
                    TheaterCalendarView(scope: .mine)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "ticket.fill")
                            .font(.title3).foregroundStyle(Theme.marquee)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("In theaters").font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("See which of your saved movies are playing or coming — list or month view")
                                .font(.caption).foregroundStyle(Theme.gray)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listRowBackground(Theme.background)
            }
            // Discovery lives in the zero state now (the "find to watch" bar was
            // removed to declutter a populated list).
            ForEach(filteredWatchlist) { item in
                if let movie = store.movie(item.movieID) {
                    // Prefetched at launch — badges render instantly.
                    WatchlistRowView(movie: movie,
                                     predicted: predicted[item.movieID]
                                         ?? store.predictedScores[item.movieID],
                                     note: item.note, watchBy: item.watchBy) {
                        logMovie = movie
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { detailMovie = movie }
                    .listRowBackground(Theme.background)
                    // Hydrate streaming/runtime so the "Streaming" and runtime
                    // filters actually work on Want to Watch (the core "what can
                    // I watch tonight?" tool).
                    .task { await store.enrich(item.movieID) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task {
                                await store.toggleWatchlist(movie: movie)   // remove
                                // Only offer Undo if it actually came off — a
                                // failed remove reverts and shows its own error.
                                if !store.isOnWatchlist(movie.tmdbID) {
                                    ToastCenter.shared.showUndo("Removed from Want to Watch") {
                                        Task { await store.toggleWatchlist(movie: movie) }   // re-add
                                    }
                                }
                            }
                        } label: { Label("Remove", systemImage: "bookmark.slash") }
                    }
                    .swipeActions(edge: .leading) {
                        Button {
                            Haptics.tap()
                            logMovie = movie
                        } label: { Label("Rank", systemImage: "plus.circle") }
                        .tint(Theme.marquee)
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: store.watchlist.count) {
            await store.refreshPredictedScores()
        }
        .overlay {
            // Empty for THIS category → always offer a one-tap path to Recs
            // (same media kind, card/swipe mode). If saves exist under the other
            // category, the message says so, but the action stays "go discover".
            if filteredWatchlist.isEmpty {
                let otherCount = watchlistCount(in: otherCategory)
                emptyList(
                    otherCount > 0
                        ? "No \(category == .movies ? "movies" : "shows") here yet — your other saves are under \(otherCategory.title)."
                        : "Nothing saved to Want to Watch yet. Tap the bookmark on any title to save it for later.",
                    actionTitle: "Find \(category == .movies ? "movies" : "shows") to watch",
                    actionIcon: "rectangle.stack") {
                    // Land on Recs with the active media kind, in the last mode.
                    tabRouter.pendingRecsTV = (category == .tvShows)
                    tabRouter.selection = .swipe
                }
            }
        }
    }

    private func emptyList(_ message: String,
                           actionTitle: String? = nil,
                           actionIcon: String = "magnifyingglass",
                           action: @escaping () -> Void = {}) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Theme.gray)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
                .multilineTextAlignment(.center)
            if let actionTitle {
                PillButton(title: actionTitle, systemImage: actionIcon,
                           style: .outlined, action: action)
            }
        }
        .padding(.horizontal, 32)
    }

}

// MARK: - Rows

/// Watched row: rank number + title, metadata, byline, runtime+availability,
/// circular personal score badge.
struct WatchedRowView: View {
    let rank: Int
    let movie: Movie
    let score: Double

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterView(url: movie.posterURL, width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(rank). \(movie.title)")
                    .font(.headline)
                Text(movie.metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                Text(movie.bylineText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                Text([movie.runtimeText, movie.availabilityText].compactMap(\.self).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .padding(.top, 2)
            }
            Spacer()
            ScoreBadge(score: score)
        }
        .padding(.vertical, 6)
    }
}

/// Watchlist row: no rank number, community average badge with count chip,
/// filled bookmark, quick-rank (+).
struct WatchlistRowView: View {
    let movie: Movie
    /// Rec Score — how much we think the user will like it.
    var predicted: Double?
    /// The "why I saved this" note from the save popup.
    var note: String?
    /// "Watch by" goal as an ISO date string.
    var watchBy: String?
    var onQuickRank: () -> Void = {}

    @Environment(RankingStore.self) private var store
    @State private var showSaveSheet = false

    /// "Watch by Jun 20", red once the date has passed.
    private var watchByLabel: (text: String, overdue: Bool)? {
        guard let watchBy,
              let date = RankingStore.watchByFormatter.date(from: watchBy) else { return nil }
        let day = Calendar.current.startOfDay(for: date)
        let today = Calendar.current.startOfDay(for: .now)
        let text = date.formatted(.dateTime.month(.abbreviated).day())
        return (day < today ? "Was due \(text)" : "Watch by \(text)", day < today)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            PosterView(url: movie.posterURL, width: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(movie.title).font(.headline)
                Text(movie.metadataLine)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                Text(movie.bylineText)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink.opacity(0.8))
                if let note {
                    Text("“\(note)”")
                        .font(.caption)
                        .italic()
                        .foregroundStyle(Theme.gray)
                        .lineLimit(2)
                }
                if let watchByLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar")
                        Text(watchByLabel.text)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(watchByLabel.overdue ? Theme.scoreRed : Theme.marquee)
                }
            }
            Spacer()
            // Score top-right, (+)/bookmark bottom-right — the same
            // corners they occupy on every artwork and card.
            VStack(alignment: .trailing, spacing: 6) {
                if let predicted {
                    VStack(spacing: 3) {
                        ScoreBadge(score: predicted)
                        Text("Rec Score")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Theme.gray)
                    }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    // Same 40pt hit targets as MovieSuggestionRow — the glyphs
                    // are small, the taps shouldn't be.
                    Button(action: onQuickRank) {
                        Image(systemName: "plus.circle")
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Rank \(movie.title)")
                    Button {
                        bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                            .frame(width: 40, height: 40)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel(store.isOnWatchlist(movie.tmdbID)
                        ? "Remove \(movie.title) from Want to Watch"
                        : "Add \(movie.title) to Want to Watch")
                }
                .font(.title3)
                .buttonStyle(.plain)
            }
            .frame(minHeight: 78)
        }
        .padding(.vertical, 6)
        .sheet(isPresented: $showSaveSheet) {
            SaveToListSheet(movie: movie)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }
}

// MARK: - Category bottom sheet

/// Zero-state "Send a rec": pick one of your ranked titles, then hand off
/// to the same Recommend sheet the movie page uses.
struct SendRecMoviePicker: View {
    @Environment(RankingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var recMovie: Movie?

    var body: some View {
        NavigationStack {
            Group {
                if store.watchedItems.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "film").font(.title).foregroundStyle(Theme.gray)
                        Text("Rank something first — recs come from titles you've watched.")
                            .font(.subheadline)
                            .foregroundStyle(Theme.gray)
                            .multilineTextAlignment(.center)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(store.watchedItems, id: \.id) { item in
                            if let movie = store.movie(item.id) {
                                Button {
                                    recMovie = movie
                                } label: {
                                    HStack(spacing: 12) {
                                        PosterView(url: movie.posterURL, width: 40)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(movie.title)
                                                .font(.subheadline.weight(.bold))
                                                .foregroundStyle(Theme.ink)
                                            Text(movie.bylineText)
                                                .font(.caption)
                                                .foregroundStyle(Theme.gray)
                                        }
                                        Spacer()
                                        Text(String(format: "%.1f", item.score))
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(Theme.scoreColor(item.score))
                                    }
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Theme.background)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Theme.background)
            .navigationTitle("Recommend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheet(item: $recMovie) { movie in
            SendRecSheet(movie: movie)
        }
    }
}
