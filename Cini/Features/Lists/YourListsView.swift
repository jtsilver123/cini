import SwiftUI
import RankingEngine

/// "MY LISTS": category switcher, Watched/Watchlist/Recs/Guides sub-tabs,
/// filter pills, sort control, and ranked rows.
struct YourListsView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter
    @State private var importQueue = ImportQueue.shared

    @State private var category: MediaCategory = .movies
    @State private var showCategorySheet = false
    @State private var subTab: SubTab = .watched
    // Sort + filters persist across launches — the list stays the way
    // the user left it.
    @AppStorage("lists.sortDescending") private var sortDescending = true
    @AppStorage("lists.genreFilter") private var genreFilter: String?
    @AppStorage("lists.decadeFilter") private var decadeFilter: Int?
    @AppStorage("lists.runtimeFilter") private var runtimeFilter: Int?   // max minutes
    @AppStorage("lists.streamingFilter") private var streamingFilter = false
    @AppStorage("lists.languageFilter") private var languageFilter: String?   // ISO 639-1
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var recCandidates: [RecCandidate] = []
    @State private var recsLoaded = false
    @State private var watchingRows: [WatchingRow] = []
    @State private var watchingLoaded = false
    @State private var showWatchingInfo = false
    @State private var predicted: [Int: Double] = [:]
    @State private var showListSearch = false
    @State private var listQuery = ""
    @State private var reorderMode = false
    @State private var pendingDeleteRating: Movie?
    @State private var showAllPending = false
    @State private var showImport = false
    @State private var directRecs: [DirectRecRow] = []
    @State private var directRecsLoaded = false
    @State private var showRecPicker = false
    // Custom lists live as tabs beside the defaults; defaults can be
    // hidden from Edit Lists (Watched/Want to Watch always stay).
    @AppStorage("lists.hiddenTabs") private var hiddenTabsRaw = ""
    @State private var customLists: [CustomList] = []
    @State private var selectedListID: UUID?
    @State private var customListMovies: [Movie] = []
    @State private var customListLoaded = false
    @State private var showEditLists = false
    @State private var showNewList = false
    @State private var newListName = ""
    @State private var showDeleteListConfirm = false

    /// The custom list currently open as a tab, if any.
    private var selectedList: CustomList? {
        selectedListID.flatMap { id in customLists.first { $0.id == id } }
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
            case .recs, .friendRecs: return !hiddenTabs.contains(tab.rawValue)
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
        case recs = "Recs"
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
                if selectedListID != nil {
                    if !reorderMode { filterRow }
                    if showListSearch { listSearchField }
                } else if subTab != .friendRecs {
                    if !reorderMode { filterRow }
                    if showListSearch { listSearchField }
                    // Recs are relevance-ordered; a date/score sort there
                    // would lie about what the toggle does.
                    if subTab != .recs { sortRow }
                }
                listContent
            }
            .nativeContentWidth()
            .background(Theme.background)
            .sheet(isPresented: $showCategorySheet) {
                CategorySheet(selection: $category)
                    .presentationDetents([.height(150)])
                    .presentationDragIndicator(.visible)
            }
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .sheet(isPresented: $showRecPicker) {
                SendRecMoviePicker()
            }
            .task {
                customLists = (try? await SupabaseService.shared.myLists()) ?? []
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
                Text("A show lands here when you tap “I'm watching this” on its page. It leaves when you rank it (you finished) or tap Stop. Friends can see what you're binging.")
            }
            .sheet(isPresented: $showEditLists, onDismiss: {
                Task { customLists = (try? await SupabaseService.shared.myLists()) ?? [] }
                if selectedListID != nil && !customLists.contains(where: { $0.id == selectedListID }) {
                    selectedListID = nil
                }
                if !visibleDefaultTabs.contains(subTab) { subTab = .watched }
            }) {
                EditListsSheet(lists: $customLists)
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
                            customLists = store.customLists
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
                    Task {
                        await store.deleteList(doomed.id)
                        customLists = store.customLists
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its movies stay on your other lists — only this list goes.")
            }
            .onChange(of: tabRouter.pendingCustomListID) { _, _ in
                consumePendingCustomList()
            }
            // Category switch with a list of the OTHER kind selected: its
            // tab just vanished — deselect rather than render a ghost.
            .onChange(of: category) { _, newCategory in
                if let selectedListID,
                   let list = customLists.first(where: { $0.id == selectedListID }),
                   list.kind != newCategory.mediaKind {
                    self.selectedListID = nil
                }
                // Watching is TV-only — switching to Movies retires that tab.
                if !visibleDefaultTabs.contains(subTab) { subTab = .watched }
            }
            .onAppear {
                consumePendingCustomList()
                if let pending = tabRouter.pendingListsTab {
                    tabRouter.pendingListsTab = nil
                    subTab = pending
                    selectedListID = nil
                    // A deep link wins over the hide preference.
                    if !visibleDefaultTabs.contains(pending) {
                        var hidden = hiddenTabs
                        hidden.remove(pending.rawValue)
                        hiddenTabsRaw = hidden.sorted().joined(separator: ",")
                    }
                    // Land where the content is: the profile count spans
                    // both categories, so "Watched (1)" must never open
                    // onto an empty Movies view when the 1 is a show.
                    // (Only once the store is real — a half-loaded store
                    // must not steer the category.)
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
                if tabRouter.pendingReorder {
                    tabRouter.pendingReorder = false
                    subTab = .watched
                    reorderMode = true
                    listQuery = ""; showListSearch = false
                    genreFilter = nil; decadeFilter = nil
                    runtimeFilter = nil; streamingFilter = false; languageFilter = nil
                    sortDescending = true   // drag offsets need canonical order
                }
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
        if let list = customLists.first(where: { $0.id == pending }) {
            withAnimation(.snappy) { select(list) }
        } else {
            Task {
                customLists = (try? await SupabaseService.shared.myLists()) ?? customLists
                if let list = customLists.first(where: { $0.id == pending }) {
                    withAnimation(.snappy) { select(list) }
                }
            }
        }
    }

    /// Selecting a list also lands on its category — a TV list's tab
    /// only exists under TV Shows.
    private func select(_ list: CustomList) {
        category = list.kind == "tv" ? .tvShows : .movies
        selectedListID = list.id
    }

    private var headerShareText: String {
        if let selectedListID,
           let list = customLists.first(where: { $0.id == selectedListID }) {
            return listShareText(name: list.name, movies: customListMovies)
        }
        return "My movie rankings live on Cini 🎬\n\(AppLinks.appStore)"
    }

    /// Plain HStack with generous tap targets — the old overlay-based
    /// layout made the ellipsis flaky to hit.
    private var header: some View {
        ZStack {
            Text("MY LISTS").font(.subheadline.weight(.semibold))
            HStack(spacing: 2) {
                Spacer()
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
                                    runtimeFilter = nil; streamingFilter = false
                                    languageFilter = nil
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
                    Button {
                        showImport = true
                    } label: {
                        Label("Import Existing List", systemImage: "square.and.arrow.down")
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
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
    }

    private var categoryRow: some View {
        // Movies / TV Shows as a segmented tab switcher (was a dropdown).
        SegmentedPillControl(
            segments: ["Movies", "TV Shows"],
            selection: Binding(get: { category == .tvShows ? 1 : 0 },
                               set: { category = $0 == 1 ? .tvShows : .movies }))
            .padding(.horizontal, 16)
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
                                        .foregroundStyle(Theme.background)
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
                ForEach(customLists.filter { $0.kind == category.mediaKind }) { list in
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
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    /// Direct recommendations friends sent you — all of them live here.
    private var friendRecsList: some View {
        List {
            if !directRecsLoaded {
                SearchSkeleton(kind: .titles, rows: 5)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Theme.background)
            }
            if directRecs.isEmpty && directRecsLoaded {
                VStack(spacing: 10) {
                    Image(systemName: "paperplane").font(.title).foregroundStyle(Theme.gray)
                    Text("No recs from friends yet")
                        .font(.subheadline.weight(.semibold))
                    Text("When a friend taps Recommend on a title and picks you, it lands here with their note.")
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
                        PillButton(title: "Send a rec", systemImage: "paperplane",
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
            ForEach(directRecs) { rec in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        AvatarView(url: rec.profiles?.avatarUrl.flatMap(URL.init), size: 28,
                                   name: preferredName(rec.profiles?.displayName, rec.profiles?.username))
                        (Text("@\(rec.profiles?.username ?? "friend")").bold()
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
        .task {
            directRecs = (try? await SupabaseService.shared.directRecs()) ?? []
            directRecsLoaded = true
            let ids = directRecs.compactMap { $0.movies?.asMovie.tmdbID }
            let map = await SupabaseService.shared.predictedScores(movieIDs: ids)
            predicted.merge(map) { _, new in new }
        }
    }

    private var listSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
            TextField("Search this list", text: $listQuery)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !listQuery.isEmpty {
                Button {
                    listQuery = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        .padding(.horizontal, 16)
    }

    private var hasActiveFilters: Bool {
        genreFilter != nil || decadeFilter != nil || runtimeFilter != nil
            || streamingFilter || languageFilter != nil
    }

    /// The persisted filter fields exposed as one shared MovieFilters.
    private var filtersBinding: Binding<MovieFilters> {
        Binding(
            get: {
                MovieFilters(genre: genreFilter, decade: decadeFilter,
                             runtime: runtimeFilter, streaming: streamingFilter,
                             language: languageFilter)
            },
            set: { filters in
                genreFilter = filters.genre
                decadeFilter = filters.decade
                runtimeFilter = filters.runtime
                streamingFilter = filters.streaming
                languageFilter = filters.language
            }
        )
    }

    private var filterRow: some View {
        MovieFilterBar(filters: filtersBinding, movies: Array(store.movies.values))
    }

    private var sortRow: some View {
        HStack {
            Button {
                sortDescending.toggle()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.arrow.down")
                    Text(subTab == .watched ? "Score" : "Date Added")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.marquee)
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                withAnimation(.snappy) {
                    showListSearch.toggle()
                    if !showListSearch { listQuery = "" }
                }
            } label: {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var listContent: some View {
        if selectedListID != nil {
            customListContent
        } else {
            switch subTab {
            case .watched: watchedList
            case .watchlist: watchlistList
            case .watching: watchingList
            case .recs: recsList
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
            if !customListLoaded {
                ListSkeleton(rows: 6)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            } else if customListMovies.isEmpty {
                Text("Nothing in this list yet — open any movie or show and tap \"Add to List.\"")
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
                    var failed = false
                    for movie in doomed {
                        do {
                            try await SupabaseService.shared.removeFromList(listID, movieID: movie.tmdbID)
                        } catch { failed = true }
                    }
                    // Reconcile from the server so a failed remove can't
                    // leave a title that reappears on next open.
                    if failed {
                        let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
                        customListMovies = ids.compactMap { store.movie($0) }
                        ToastCenter.shared.saveFailed()
                    } else {
                        // Offer Undo — consistent with Want to Watch / watched.
                        let label = doomed.count == 1
                            ? "Removed \(doomed[0].title)" : "Removed \(doomed.count) titles"
                        ToastCenter.shared.showUndo(label) {
                            Task {
                                for movie in doomed {
                                    try? await SupabaseService.shared.addToList(listID, movieID: movie.tmdbID)
                                }
                                let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
                                customListMovies = ids.compactMap { store.movie($0) }
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: selectedListID) {
            guard let listID = selectedListID else { return }
            customListMovies = []
            customListLoaded = false
            let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
            let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.tmdbId, $0.asMovie) })
            customListMovies = ids.compactMap { byID[$0] ?? store.movie($0) }
            for movie in customListMovies { store.cache(movie) }
            customListLoaded = true
        }
    }

    /// Category check + the shared five-filter predicate.
    private func passesFilters(_ movie: Movie) -> Bool {
        guard category.matches(movie) else { return false }
        return filtersBinding.wrappedValue.passes(movie)
    }

    private var filteredWatched: [ScoredItem<Int>] {
        // Reorder mode always shows canonical order — drag offsets feed
        // straight into the engine and a reversed list would corrupt them.
        let items = (sortDescending || reorderMode)
            ? store.watchedItems : store.watchedItems.reversed()
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
        importQueue.entries.filter { !store.isWatched($0.movieID) }
    }

    @ViewBuilder
    private var pendingSection: some View {
        HStack(spacing: 8) {
            Text("Pending").font(.headline)
            Text("\(pendingEntries.count)")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.background)
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
                emptyList("Rank your first movie or show and your list starts here.",
                          actionTitle: "Find something") {
                    tabRouter.selection = .search
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
                    } label: { Label("Stop", systemImage: "stop.circle") }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if watchingLoaded && watchingRows.isEmpty {
                emptyList("Mark a show “I'm watching this” on its page and it shows up here.",
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
            if store.watchlist.isEmpty {
                emptyList("Tap the bookmark on any title to save it for later.",
                          actionTitle: "Browse popular") {
                    tabRouter.pendingSearchBrowse = .popular
                    tabRouter.selection = .search
                }
            } else if filteredWatchlist.isEmpty, watchlistCount(in: otherCategory) > 0 {
                emptyList(categoryHiddenMessage(count: watchlistCount(in: otherCategory)),
                          actionTitle: "Show \(otherCategory.title)",
                          actionIcon: otherCategory.icon) {
                    withAnimation(.snappy) { category = otherCategory }
                }
            }
        }
    }

    private var filteredRecs: [RecCandidate] {
        recCandidates.filter { passesFilters($0.movie) }
    }

    /// Recs: friends' loves weighted by taste match, then TMDB-similar to the
    /// user's #1, then trending — first match wins per movie. The filter
    /// pills above (genre/decade/runtime/streaming/language) apply here too,
    /// so "what should I watch tonight?" is just Recs + a couple of taps.
    private var recsList: some View {
        List {
            Button {
                guard let pick = filteredRecs.randomElement() else { return }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                detailMovie = pick.movie
            } label: {
                Label("Surprise me", systemImage: "dice")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
            }
            .listRowBackground(Theme.background)

            ForEach(filteredRecs) { candidate in
                VStack(alignment: .leading, spacing: 4) {
                    WatchlistRowView(movie: candidate.movie,
                                     predicted: predicted[candidate.movie.tmdbID]) {
                        logMovie = candidate.movie
                    }
                    Text(candidate.reason)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.scoreGreen)
                }
                .contentShape(Rectangle())
                .onTapGesture { detailMovie = candidate.movie }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .overlay {
            if recsLoaded && filteredRecs.isEmpty {
                emptyList("No recs match these filters — loosen one, or follow more friends.")
            } else if !recsLoaded && recCandidates.isEmpty {
                SearchSkeleton(kind: .titles, rows: 6)
                    .padding(.horizontal, 16)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .task { await loadRecs() }
    }

    private func loadRecs() async {
        guard recCandidates.isEmpty else { return }
        // All three sources fetch concurrently; the order of the tab
        // stays friends → similar → trending.
        let topID = store.watchedItems.first?.id
        async let friendRecsTask = SupabaseService.shared.recsForUser()
        async let similarTask = similarToTop(topID)
        async let trendingTask = TMDBService.shared.trending()

        var pending: [(id: Int, reason: String)] = []
        var seen = Set<Int>()

        // 1. Friend-powered (taste-match weighted) from the database.
        if let friendRecs = try? await friendRecsTask {
            let rows = (try? await SupabaseService.shared.movies(ids: friendRecs.map(\.movieId))) ?? []
            for row in rows { store.cache(row.asMovie) }
            for rec in friendRecs where seen.insert(rec.movieId).inserted {
                let who = rec.topFriendUsername.map { "@\($0)" } ?? "friends"
                pending.append((rec.movieId, rec.friendCount > 1
                    ? "Loved by \(who) + \(rec.friendCount - 1) more"
                    : "Loved by \(who)"))
            }
        }

        // 2. Similar to the user's current #1.
        if let similar = await similarTask {
            let topTitle = topID.flatMap { store.movie($0)?.title } ?? "your #1"
            for movie in similar.prefix(10)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Because you loved \(topTitle)"))
            }
        }

        // 3. Trending keeps the tab alive while the social graph is small.
        if pending.count < 10, let trending = try? await trendingTask {
            for movie in trending.prefix(10)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                pending.append((movie.tmdbID, "Trending this week"))
            }
        }

        // Enrich a few at a time instead of one by one — serially this
        // was dozens of back-to-back round-trips before recs appeared.
        await enrichConcurrently(pending.map(\.id))

        recCandidates = pending.compactMap { candidate in
            store.movie(candidate.id).map { RecCandidate(movie: $0, reason: candidate.reason) }
        }
        recsLoaded = true
    }

    private func similarToTop(_ topID: Int?) async -> [Movie]? {
        guard let topID else { return nil }
        return try? await TMDBService.shared.similar(to: topID)
    }

    /// At most six enriches in flight — parallel enough to be fast,
    /// polite enough for TMDB.
    private func enrichConcurrently(_ ids: [Int]) async {
        let store = self.store
        await withTaskGroup(of: Void.self) { group in
            var remaining = ids[...]
            for _ in 0..<min(6, remaining.count) {
                let id = remaining.removeFirst()
                group.addTask { await store.enrich(id) }
            }
            while await group.next() != nil {
                if let id = remaining.popFirst() {
                    group.addTask { await store.enrich(id) }
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
                HStack(spacing: 14) {
                    Button(action: onQuickRank) {
                        Image(systemName: "plus.circle")
                    }
                    .accessibilityLabel("Rank \(movie.title)")
                    Button {
                        bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
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

struct CategorySheet: View {
    @Binding var selection: MediaCategory
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Choose a category").font(.title3.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.ink)
                        .frame(width: 40, height: 40)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            CategoryChips(selection: $selection) { _ in dismiss() }
            Spacer()
        }
        .padding(20)
    }
}


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
                                            .foregroundStyle(Theme.scoreGreen)
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
            .navigationTitle("Send a Rec")
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
