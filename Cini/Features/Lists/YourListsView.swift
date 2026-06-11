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
    @State private var showFilters = false
    @State private var showListSearch = false
    @State private var listQuery = ""
    @State private var reorderMode = false
    @State private var showAllPending = false
    @State private var showImport = false
    @State private var directRecs: [DirectRecRow] = []
    @State private var directRecsLoaded = false
    @State private var trendingMovies: [Movie] = []

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
        case trending = "Trending"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                categoryRow
                subTabs
                if subTab != .friendRecs && subTab != .trending {
                    if showFilters { filterRow }
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
            .onAppear {
                if let pending = tabRouter.pendingListsTab {
                    tabRouter.pendingListsTab = nil
                    subTab = pending
                }
                if tabRouter.pendingReorder {
                    tabRouter.pendingReorder = false
                    subTab = .watched
                    reorderMode = true
                    showFilters = false; listQuery = ""; showListSearch = false
                    genreFilter = nil; decadeFilter = nil
                    runtimeFilter = nil; streamingFilter = false; languageFilter = nil
                }
                // Persisted filters must never act invisibly.
                if hasActiveFilters { showFilters = true }
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
        }
    }

    private var header: some View {
        HStack {
            Spacer()
            Text("MY LISTS").font(.subheadline.weight(.semibold))
            Spacer()
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 16) {
                ShareLink(item: "My movie rankings live on Cini 🎬") {
                    Image(systemName: "square.and.arrow.up")
                }
                Menu {
                    Button {
                        withAnimation(.snappy) { showFilters.toggle() }
                    } label: {
                        Label(showFilters ? "Hide filters" : "Filter this list",
                              systemImage: "line.3.horizontal.decrease.circle")
                    }
                    Button {
                        withAnimation(.snappy) {
                            showListSearch.toggle()
                            if !showListSearch { listQuery = "" }
                        }
                    } label: {
                        Label("Search this list", systemImage: "magnifyingglass")
                    }
                    if subTab == .watched {
                        Button {
                            withAnimation(.snappy) {
                                reorderMode.toggle()
                                if reorderMode {   // reorder works on the full list
                                    showFilters = false
                                    listQuery = ""
                                    showListSearch = false
                                    genreFilter = nil; decadeFilter = nil
                                    runtimeFilter = nil; streamingFilter = false
                                    languageFilter = nil
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
                }
            }
            .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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
                ForEach(SubTab.allCases, id: \.self) { tab in
                    Button {
                        withAnimation(.snappy) { subTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            HStack(spacing: 5) {
                                Text(tab.rawValue)
                                    .font(.subheadline.weight(subTab == tab ? .bold : .regular))
                                    .foregroundStyle(subTab == tab ? Theme.ink : Theme.gray)
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
                                .fill(subTab == tab ? Theme.ink : .clear)
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

    /// What's big on TMDB this week, scored for YOUR taste.
    private var trendingList: some View {
        List {
            ForEach(trendingMovies) { movie in
                WatchlistRowView(movie: movie, predicted: predicted[movie.tmdbID]) {
                    logMovie = movie
                }
                .contentShape(Rectangle())
                .onTapGesture { detailMovie = movie }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .overlay {
            if trendingMovies.isEmpty {
                ProgressView()
            }
        }
        .task {
            guard trendingMovies.isEmpty else { return }
            trendingMovies = (try? await TMDBService.shared.trending()) ?? []
            for movie in trendingMovies { store.cache(movie) }
            let map = await SupabaseService.shared.predictedScores(
                movieIDs: trendingMovies.map(\.tmdbID))
            predicted.merge(map) { _, new in new }
        }
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
                        AvatarView(url: rec.profiles?.avatarUrl.flatMap(URL.init), size: 28)
                        (Text("@\(rec.profiles?.username ?? "friend")").bold()
                            + Text(" thinks you'll love this"))
                            .font(.caption)
                        Spacer()
                        Button {
                            Task { await SupabaseService.shared.dismissDirectRec(id: rec.id) }
                            withAnimation(.snappy) { directRecs.removeAll { $0.id == rec.id } }
                        } label: {
                            Image(systemName: "xmark").font(.caption).foregroundStyle(Theme.gray)
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

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if hasActiveFilters {
                    Button {
                        withAnimation(.snappy) {
                            genreFilter = nil; decadeFilter = nil
                            runtimeFilter = nil; streamingFilter = false
                            languageFilter = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .padding(10)
                            .foregroundStyle(Theme.ink)
                    }
                    .buttonStyle(.plain)
                    .glassCapsule()
                }

                Menu {
                    Button("All Genres") { genreFilter = nil }
                    ForEach(allGenres, id: \.self) { genre in
                        Button(genre) { genreFilter = genre }
                    }
                } label: {
                    FilterPill(title: genreFilter ?? "Genre")
                }
                Menu {
                    Button("All Decades") { decadeFilter = nil }
                    ForEach(Array(stride(from: 2020, through: 1950, by: -10)), id: \.self) { decade in
                        Button("\(String(decade))s") { decadeFilter = decade }
                    }
                } label: {
                    FilterPill(title: decadeFilter.map { "\(String($0))s" } ?? "Decade")
                }
                Menu {
                    Button("Anywhere") { streamingFilter = false }
                    Button("Streaming now") { streamingFilter = true }
                } label: {
                    FilterPill(title: streamingFilter ? "Streaming now" : "Streaming")
                }
                Menu {
                    Button("Any runtime") { runtimeFilter = nil }
                    Button("Under 100 min") { runtimeFilter = 100 }
                    Button("Under 2 hours") { runtimeFilter = 120 }
                    Button("Under 2½ hours") { runtimeFilter = 150 }
                } label: {
                    FilterPill(title: runtimeFilter.map { "< \($0) min" } ?? "Runtime")
                }
                Menu {
                    Button("All Languages") { languageFilter = nil }
                    ForEach(allLanguages, id: \.code) { language in
                        Button(language.name) { languageFilter = language.code }
                    }
                } label: {
                    FilterPill(title: languageFilter.flatMap {
                        Locale.current.localizedString(forLanguageCode: $0)
                    } ?? "Language")
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.vertical, 10)
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
        switch subTab {
        case .watched: watchedList
        case .watchlist: watchlistList
        case .recs: recsList
        case .friendRecs: friendRecsList
        case .trending: trendingList
        }
    }

    /// Shared filter predicate: genre, decade, runtime, streaming, language.
    private func passesFilters(_ movie: Movie) -> Bool {
        if movie.mediaKind != category.mediaKind && !(category == .movies && movie.mediaKind == "movie") {
            return false
        }
        if let genreFilter, !movie.genres.contains(genreFilter) { return false }
        if let decadeFilter, let year = movie.releaseYear,
           !(decadeFilter..<decadeFilter + 10).contains(year) { return false }
        if let runtimeFilter, let runtime = movie.runtimeMinutes, runtime > runtimeFilter { return false }
        if streamingFilter && movie.streamingOn.isEmpty { return false }
        if let languageFilter, movie.originalLanguage != languageFilter { return false }
        return true
    }

    private var filteredWatched: [ScoredItem<Int>] {
        let items = sortDescending ? store.watchedItems : store.watchedItems.reversed()
        let query = listQuery.trimmingCharacters(in: .whitespaces).lowercased()
        return items.filter { item in
            guard let movie = store.movie(item.id) else { return true }
            guard passesFilters(movie) else { return false }
            return query.isEmpty || movie.title.lowercased().contains(query)
        }
    }

    private var allLanguages: [(code: String, name: String)] {
        let codes = Set(store.movies.values.compactMap(\.originalLanguage))
        return codes.compactMap { code in
            Locale.current.localizedString(forLanguageCode: code).map { (code, $0) }
        }
        .sorted { $0.1 < $1.1 }
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

    private var allGenres: [String] {
        Array(Set(store.movies.values.flatMap(\.genres))).sorted()
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
                HStack(spacing: 16) {
                    Button(action: onQuickRank) {
                        Image(systemName: "plus.circle")
                    }
                    Button {
                        Task { await store.toggleWatchlist(movie: movie) }
                    } label: {
                        Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                    }
                }
                .font(.title3)
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            Spacer()
            if let predicted {
                VStack(spacing: 3) {
                    ScoreBadge(score: predicted)
                    Text("Rec Score")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.gray)
                }
            }
        }
        .padding(.vertical, 6)
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
                        .foregroundStyle(selection == category ? .white : Theme.ink)
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

