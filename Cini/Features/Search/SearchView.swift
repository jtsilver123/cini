import SwiftUI

/// Center tab: Movies · Members search, year/decade filter, quick pills,
/// recents, and "Movies you may have seen" seeded by import + popularity.
struct SearchView: View {
    @Environment(RankingStore.self) private var store

    @State private var importQueue = ImportQueue.shared
    @State private var tab = 0   // 0 = Movies, 1 = Members
    @State private var query = ""
    @State private var movieResults: [Movie] = []
    @State private var memberResults: [ProfileRow] = []
    @State private var followedFromSearch: Set<UUID> = []
    @State private var recents: [Movie] = RecentSearches.load()
    @State private var maybeSeen: [Movie] = []
    @State private var dismissedMaybeSeen: Set<Int> = []
    @State private var showAllMaybeSeen = false
    @State private var showImport = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    var body: some View {
        NavigationStack {
            // Tabs, the search field, and the pill row stay frozen; only
            // results/recents scroll underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    tabsRow
                    searchFields
                    quickPills
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 12)
                .background(Theme.background)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if tab == 0 {
                            if !movieResults.isEmpty {
                                resultsSection
                            } else {
                                recentsSection
                                maybeSeenSection
                            }
                        } else {
                            membersSection
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .background(Theme.background)
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .sheet(isPresented: $showImport) {
                LetterboxdImportView()
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
            .task { await loadSuggestions() }
            .onAppear {
                // Arriving via the + tab with nothing typed: keyboard up,
                // ready to log a movie.
                if query.isEmpty { searchFocused = true }
            }
        }
    }

    // MARK: Tabs: Movies · Members

    private var tabsRow: some View {
        HStack(spacing: 0) {
            tabButton("Movies", icon: "film", index: 0)
            tabButton("Members", icon: "person.2", index: 1)
        }
    }

    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button {
            withAnimation(.snappy) { tab = index }
        } label: {
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                    Text(title).font(.headline)
                }
                .foregroundStyle(tab == index ? Theme.marquee : Theme.gray)
                Rectangle()
                    .fill(tab == index ? Theme.marquee : .clear)
                    .frame(height: 2.5)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
    }

    // MARK: Fields

    private var searchFields: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.gray)
                TextField(tab == 0 ? "Search movie, genre, mood" : "Search members", text: $query)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onChange(of: query) { _, _ in scheduleSearch() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }

    private var quickPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PillButton(title: "Trending", systemImage: "chart.line.uptrend.xyaxis") {
                    Task {
                        movieResults = (try? await TMDBService.shared.trending()) ?? []
                        for movie in movieResults { store.cache(movie) }
                    }
                }
                NavigationLink {
                    RecsForYouScreen()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "heart").font(.subheadline.weight(.semibold))
                        Text("Recs").font(.subheadline.weight(.semibold))
                    }
                    .foregroundStyle(Theme.marquee)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .overlay(Capsule().strokeBorder(Theme.marquee, lineWidth: 1.2))
                }
                .buttonStyle(.plain)
            }
        }
        .scrollClipDisabled()
    }

    // MARK: Results

    private var resultsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(movieResults) { movie in
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { logMovie = movie },
                    onOpen: {
                        recents.removeAll { $0.tmdbID == movie.tmdbID }
                        recents.insert(movie, at: 0)
                        recents = Array(recents.prefix(10))
                        RecentSearches.save(recents)
                        detailMovie = movie
                    }
                )
                Divider()
            }
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(memberResults) { member in
                NavigationLink {
                    MemberProfileView(userID: member.id, username: member.username)
                } label: {
                    HStack(spacing: 12) {
                        AvatarView(url: member.avatarUrl.flatMap(URL.init), size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(member.displayName.isEmpty ? member.username : member.displayName)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("@\(member.username)").font(.caption).foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        PillButton(title: followedFromSearch.contains(member.id) ? "Following" : "Follow",
                                   style: .outlined) {
                            Task {
                                if followedFromSearch.contains(member.id) {
                                    try? await SupabaseService.shared.unfollow(member.id)
                                    followedFromSearch.remove(member.id)
                                } else {
                                    try? await SupabaseService.shared.follow(member.id)
                                    followedFromSearch.insert(member.id)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
    }

    private var recentsSection: some View {
        Group {
            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recents").font(.headline)
                    ForEach(recents.prefix(5)) { movie in
                        HStack(spacing: 12) {
                            Image(systemName: "clock").foregroundStyle(Theme.gray)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(movie.title).font(.subheadline.weight(.semibold))
                                Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
                            }
                            Spacer()
                            Button {
                                recents.removeAll { $0.tmdbID == movie.tmdbID }
                                RecentSearches.save(recents)
                            } label: {
                                Image(systemName: "xmark").foregroundStyle(Theme.gray)
                            }
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                    }
                }
            }
        }
    }

    // MARK: "Movies you may have seen"

    /// Imported queue first (persistent, favorites-first); popular titles
    /// only as a cold-start fallback before any import.
    private var queueEntries: [ImportQueue.Entry] {
        importQueue.entries.filter { !store.isWatched($0.movieID) }
    }

    private var visibleMaybeSeen: [Movie] {
        maybeSeen.filter { !dismissedMaybeSeen.contains($0.tmdbID) && !store.isWatched($0.tmdbID) }
    }

    @ViewBuilder
    private var maybeSeenSection: some View {
        if !queueEntries.isEmpty {
            importedQueueSection
        } else {
            popularFallbackSection
        }
    }

    private var importedQueueSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Movies you may have seen").font(.headline)
                Spacer()
                Button("Import more") { showImport = true }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.marquee)
            }
            Text("From your import (Ranked \(importQueue.rankedFromImport) of \(importQueue.totalImported))")
                .font(.caption)
                .foregroundStyle(Theme.gray)

            ForEach(queueEntries.prefix(showAllMaybeSeen ? 200 : 4)) { entry in
                let movie = store.movie(entry.movieID)
                    ?? Movie(tmdbID: entry.movieID, mediaKind: "movie", title: entry.title,
                             releaseYear: entry.year, posterPath: nil, backdropPath: nil,
                             genres: [], certification: nil, runtimeMinutes: nil,
                             director: nil, overview: nil)
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { logMovie = movie },
                    onOpen: { detailMovie = movie },
                    onDismiss: { importQueue.dismiss(entry.movieID) }
                )
                .task { await store.enrich(entry.movieID) }
                Divider()
            }

            if queueEntries.count > 4 && !showAllMaybeSeen {
                seeAllButton(count: queueEntries.count)
            }
        }
        .padding(.top, 8)
    }

    private var popularFallbackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Movies you may have seen").font(.headline)

            Button {
                showImport = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.title3)
                        .foregroundStyle(Theme.marquee)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Import from Letterboxd or IMDb")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("Queue your whole history to rank — favorites first")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                }
                .padding(14)
            }
            .buttonStyle(.plain)
            .floatingCard(cornerRadius: 14)
            .padding(.vertical, 6)

            ForEach(visibleMaybeSeen.prefix(showAllMaybeSeen ? 100 : 4)) { movie in
                MovieSuggestionRow(
                    movie: movie,
                    onRank: { logMovie = movie },
                    onOpen: { detailMovie = movie },
                    onDismiss: { dismissedMaybeSeen.insert(movie.tmdbID) }
                )
                Divider()
            }

            if visibleMaybeSeen.count > 4 && !showAllMaybeSeen {
                seeAllButton(count: visibleMaybeSeen.count)
            }
        }
        .padding(.top, 8)
    }

    private func seeAllButton(count: Int) -> some View {
        Button {
            withAnimation { showAllMaybeSeen = true }
        } label: {
            HStack {
                Text("See All (\(count))").font(.subheadline.weight(.semibold))
                Spacer()
                Image(systemName: "chevron.down")
            }
            .foregroundStyle(Theme.marquee)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    // MARK: Data

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            movieResults = []
            memberResults = []
            return
        }
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(250))   // debounce
            guard !Task.isCancelled else { return }
            if tab == 0 {
                movieResults = (try? await TMDBService.shared.search(query: text, year: nil)) ?? []
                for movie in movieResults { store.cache(movie) }
            } else {
                memberResults = (try? await SupabaseService.shared.searchMembers(query: text)) ?? []
            }
        }
    }

    private func loadSuggestions() async {
        guard maybeSeen.isEmpty else { return }
        // Seeded from Letterboxd/IMDb import (onboarding) + popular titles.
        maybeSeen = (try? await TMDBService.shared.popular()) ?? []
        for movie in maybeSeen { store.cache(movie) }
    }
}

/// Suggestion row: title, year + director, quick (+) rank, bookmark, dismiss.
struct MovieSuggestionRow: View {
    let movie: Movie
    var onRank: () -> Void = {}
    var onOpen: () -> Void = {}
    var onDismiss: (() -> Void)?

    @Environment(RankingStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            PosterView(url: movie.posterURL, width: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(movie.title).font(.subheadline.weight(.semibold))
                Text(movie.bylineText).font(.caption).foregroundStyle(Theme.gray)
            }
            Spacer()
            HStack(spacing: 14) {
                Button(action: onRank) {
                    Image(systemName: "plus.circle")
                }
                Button {
                    Task { await store.toggleWatchlist(movie: movie) }
                } label: {
                    Image(systemName: store.isOnWatchlist(movie.tmdbID) ? "bookmark.fill" : "bookmark")
                        .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.marquee : Theme.ink)
                }
                if let onDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark").foregroundStyle(Theme.gray)
                    }
                }
            }
            .font(.title3)
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
    }
}


/// Recent searches persist across launches (UserDefaults, newest first).
enum RecentSearches {
    private static let key = "cini.recentSearches"

    static func load() -> [Movie] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Movie].self, from: data)) ?? []
    }

    static func save(_ movies: [Movie]) {
        if let data = try? JSONEncoder().encode(Array(movies.prefix(10))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
