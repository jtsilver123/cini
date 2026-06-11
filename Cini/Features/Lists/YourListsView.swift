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
    @State private var predicted: [Int: Double] = [:]
    @State private var showListSearch = false
    @State private var listQuery = ""
    @State private var reorderMode = false
    @State private var showAllPending = false
    @State private var showImport = false
    @State private var directRecs: [DirectRecRow] = []
    @State private var directRecsLoaded = false
    // Custom lists live as tabs beside the defaults; defaults can be
    // hidden from Edit Lists (Watched/Want to Watch always stay).
    @AppStorage("lists.hiddenTabs") private var hiddenTabsRaw = ""
    @State private var customLists: [CustomList] = []
    @State private var selectedListID: UUID?
    @State private var customListMovies: [Movie] = []
    @State private var showEditLists = false
    @State private var showNewList = false
    @State private var newListName = ""

    private var hiddenTabs: Set<String> {
        Set(hiddenTabsRaw.split(separator: ",").map(String.init))
    }

    private var visibleDefaultTabs: [SubTab] {
        SubTab.allCases.filter { tab in
            switch tab {
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
        case recs = "Recs"
        case friendRecs = "Friend Recs"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                categoryRow
                subTabs
                if subTab != .friendRecs && selectedListID == nil {
                    // Filters are first-class on every personal list —
                    // always visible, never acting from hiding.
                    if !reorderMode { filterRow }
                    if showListSearch { listSearchField }
                    // Recs are relevance-ordered; a date/score sort there
                    // would lie about what the toggle does.
                    if subTab != .recs { sortRow }
                }
                listContent
            }
            .background(Theme.background)
            .sheet(isPresented: $showCategorySheet) {
                CategorySheet(selection: $category)
                    .presentationDetents([.height(260)])
            }
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .task {
                customLists = (try? await SupabaseService.shared.myLists()) ?? []
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
                        if let list = try? await SupabaseService.shared.createList(name: name) {
                            customLists.insert(list, at: 0)
                            withAnimation(.snappy) { selectedListID = list.id }
                        }
                    }
                }
                Button("Cancel", role: .cancel) { newListName = "" }
            } message: {
                Text("Add movies to it from any movie page with \"Add to List\".")
            }
            .onAppear {
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

    private var headerShareText: String {
        if let selectedListID,
           let list = customLists.first(where: { $0.id == selectedListID }) {
            return listShareText(name: list.name, movies: customListMovies)
        }
        return "My movie rankings live on Cini 🎬"
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
        Button { showCategorySheet = true } label: {
            HStack(spacing: 6) {
                Text(category.title).font(Theme.serif(30))
                Image(systemName: "chevron.down").font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Theme.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
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

                // Your own lists ride the same row.
                ForEach(customLists) { list in
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
            if directRecs.isEmpty && directRecsLoaded {
                VStack(spacing: 8) {
                    Image(systemName: "paperplane").font(.title).foregroundStyle(Theme.gray)
                    Text("No recs from friends yet")
                        .font(.subheadline.weight(.semibold))
                    Text("When a friend taps Recommend on a movie and picks you, it lands here with their note.")
                        .font(.caption)
                        .foregroundStyle(Theme.gray)
                        .multilineTextAlignment(.center)
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
                            Task { await SupabaseService.shared.dismissDirectRec(id: rec.id) }
                            withAnimation(.snappy) { directRecs.removeAll { $0.id == rec.id } }
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
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
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
            case .recs: recsList
            case .friendRecs: friendRecsList
            }
        }
    }

    /// One of the user's own lists, inline — same rows, swipe to remove.
    private var customListContent: some View {
        List {
            if customListMovies.isEmpty {
                Text("Empty so far — add movies with \"Add to List\" on any movie page.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.gray)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 32)
                    .listRowBackground(Theme.background)
                    .listRowSeparator(.hidden)
            }
            ForEach(customListMovies) { movie in
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
                let doomed = offsets.map { customListMovies[$0] }
                customListMovies.remove(atOffsets: offsets)
                Task {
                    for movie in doomed {
                        try? await SupabaseService.shared.removeFromList(listID, movieID: movie.tmdbID)
                    }
                }
            }
        }
        .listStyle(.plain)
        .task(id: selectedListID) {
            guard let listID = selectedListID else { return }
            customListMovies = []
            let ids = (try? await SupabaseService.shared.listMovieIDs(listID)) ?? []
            let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
            let byID = Dictionary(uniqueKeysWithValues: rows.map { ($0.tmdbId, $0.asMovie) })
            customListMovies = ids.compactMap { byID[$0] ?? store.movie($0) }
            for movie in customListMovies { store.cache(movie) }
        }
    }

    /// Category check + the shared five-filter predicate.
    private func passesFilters(_ movie: Movie) -> Bool {
        if movie.mediaKind != category.mediaKind && !(category == .movies && movie.mediaKind == "movie") {
            return false
        }
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
                ?? Movie(tmdbID: entry.movieID, mediaKind: "movie", title: entry.title,
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
                }
            }
            .onMove { from, to in
                Task { await store.moveRanked(fromOffsets: from, toOffset: to) }
            }
        }
        .listStyle(.plain)
        .environment(\.editMode, .constant(reorderMode ? .active : .inactive))
        .overlay {
            if store.watchedItems.isEmpty && pendingEntries.isEmpty {
                emptyList("Log your first movie with the + tab.")
            }
        }
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

    private var watchlistList: some View {
        List {
            ForEach(filteredWatchlist) { item in
                if let movie = store.movie(item.movieID) {
                    // Prefetched at launch — badges render instantly.
                    WatchlistRowView(movie: movie,
                                     predicted: predicted[item.movieID]
                                         ?? store.predictedScores[item.movieID]) {
                        logMovie = movie
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { detailMovie = movie }
                    .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        .task(id: store.watchlist.count) {
            await store.refreshPredictedScores()
        }
        .overlay {
            if store.watchlist.isEmpty {
                emptyList("Bookmark movies you want to watch.")
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
            }
        }
        .task { await loadRecs() }
    }

    private func loadRecs() async {
        guard recCandidates.isEmpty else { return }
        var result: [RecCandidate] = []
        var seen = Set<Int>()

        // 1. Friend-powered (taste-match weighted) from the database.
        if let friendRecs = try? await SupabaseService.shared.recsForUser() {
            let rows = (try? await SupabaseService.shared.movies(ids: friendRecs.map(\.movieId))) ?? []
            for row in rows { store.cache(row.asMovie) }
            for rec in friendRecs where seen.insert(rec.movieId).inserted {
                await store.enrich(rec.movieId)
                if let movie = store.movie(rec.movieId) {
                    let who = rec.topFriendUsername.map { "@\($0)" } ?? "friends"
                    result.append(RecCandidate(
                        movie: movie,
                        reason: rec.friendCount > 1
                            ? "Loved by \(who) + \(rec.friendCount - 1) more"
                            : "Loved by \(who)"
                    ))
                }
            }
        }

        // 2. Similar to the user's current #1.
        if let top = store.watchedItems.first,
           let similar = try? await TMDBService.shared.similar(to: top.id) {
            let topTitle = store.movie(top.id)?.title ?? "your #1"
            for movie in similar.prefix(10)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                await store.enrich(movie.tmdbID)
                if let enriched = store.movie(movie.tmdbID) {
                    result.append(RecCandidate(movie: enriched, reason: "Because you loved \(topTitle)"))
                }
            }
        }

        // 3. Trending keeps the tab alive while the social graph is small.
        if result.count < 10, let trending = try? await TMDBService.shared.trending() {
            for movie in trending.prefix(10)
            where seen.insert(movie.tmdbID).inserted && !store.isWatched(movie.tmdbID) {
                store.cache(movie)
                await store.enrich(movie.tmdbID)
                if let enriched = store.movie(movie.tmdbID) {
                    result.append(RecCandidate(movie: enriched, reason: "Trending this week"))
                }
            }
        }

        recCandidates = result
        recsLoaded = true
    }

    private func emptyList(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(Theme.gray)
            Text(message).font(.subheadline).foregroundStyle(Theme.gray)
        }
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
    var onQuickRank: () -> Void = {}

    @Environment(RankingStore.self) private var store
    @State private var showSaveSheet = false

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
                    Button {
                        bookmarkTapped(movie: movie, store: store) { showSaveSheet = true }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                    }
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

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Choose a category").font(.title3.weight(.bold))
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark").foregroundStyle(Theme.ink)
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(MediaCategory.allCases) { category in
                    Button {
                        selection = category
                        dismiss()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: category.icon)
                            Text(category.title).font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .foregroundStyle(selection == category ? Theme.background : Theme.ink)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selection == category ? Theme.marquee : .clear)
                                .overlay(RoundedRectangle(cornerRadius: 12)
                                    .strokeBorder(selection == category ? .clear : Theme.hairline))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
        }
        .padding(20)
    }
}

