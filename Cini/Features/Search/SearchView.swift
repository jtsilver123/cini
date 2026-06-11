import SwiftUI

/// Center tab: Movies · Members search, year/decade filter, quick pills,
/// recents, and popular "Movies you may have seen" suggestions.
struct SearchView: View {
    @Environment(RankingStore.self) private var store
    @Environment(TabRouter.self) private var tabRouter

    @State private var tab = 0   // 0 = Movies, 1 = Members
    @State private var query = ""
    @State private var movieResults: [Movie] = []
    @State private var memberResults: [ProfileRow] = []
    @State private var followedFromSearch: Set<UUID> = []
    @State private var suggested: [SuggestedMember] = []
    @State private var contactMatches: [SuggestedMember] = []
    @State private var contactsChecked = false
    @State private var showInvite = false
    @State private var recents: [Movie] = RecentSearches.load()
    @State private var maybeSeen: [Movie] = []
    @State private var dismissedMaybeSeen: Set<Int> = []
    @State private var showAllMaybeSeen = false
    @State private var showImport = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var searchTask: Task<Void, Never>?
    @State private var isSearching = false
    @State private var browse: BrowseKind?
    @State private var browseResults: [Movie] = []
    @FocusState private var searchFocused: Bool

    /// One-tap browsing for people who don't want to type.
    enum BrowseKind: String, CaseIterable {
        case releases = "Release Date"
        case popular = "Popular"
        case trending = "Trending"

        var icon: String {
            switch self {
            case .releases: "calendar"
            case .popular: "flame"
            case .trending: "chart.line.uptrend.xyaxis"
            }
        }
    }

    var body: some View {
        NavigationStack {
            // Tabs, the search field, and the pill row stay frozen; only
            // results/recents scroll underneath.
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 16) {
                    brandRow
                    tabsRow
                    searchFields
                    if tab == 0 { browseRow }
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
                            } else if browse != nil {
                                browseSection
                            } else {
                                recentsSection
                                maybeSeenSection
                            }
                        } else if memberResults.isEmpty && query.trimmingCharacters(in: .whitespaces).isEmpty {
                            suggestedSection
                        } else {
                            membersSection
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .scrollDismissesKeyboard(.immediately)
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
                if tabRouter.openMembersSearch {
                    tabRouter.openMembersSearch = false
                    tab = 1
                } else if query.isEmpty {
                    // Arriving via the + tab with nothing typed: keyboard
                    // up, ready to log a movie.
                    searchFocused = true
                }
            }
        }
    }

    // MARK: Brand row — wordmark + X back to the page underneath

    private var brandRow: some View {
        HStack {
            Text("cini")
                .font(Theme.wordmark)
                .foregroundStyle(Theme.marquee)
            Spacer()
            Button {
                // Release search focus FIRST — while the field is focused,
                // the system search tab can swallow a programmatic tab
                // switch and the X appears to do nothing.
                searchFocused = false
                UIApplication.shared.sendAction(
                    #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(80))
                    withAnimation(.snappy) { tabRouter.closeSearch() }
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(Theme.fill))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
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
                TextField(tab == 0 ? "Search movies & TV shows" : "Search members", text: $query)
                    .autocorrectionDisabled()
                    .focused($searchFocused)
                    .onChange(of: query) { _, _ in scheduleSearch() }
                if isSearching {
                    ProgressView().controlSize(.small)
                } else if !query.isEmpty {
                    Button {
                        query = ""
                        scheduleSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.gray)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
        }
    }

    /// Release Date · Popular · Trending — browse without typing.
    private var browseRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(BrowseKind.allCases, id: \.self) { kind in
                    PillButton(title: kind.rawValue, systemImage: kind.icon,
                               style: browse == kind ? .filled : .outlined) {
                        withAnimation(.snappy) {
                            browse = browse == kind ? nil : kind
                        }
                        Task { await loadBrowse() }
                    }
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder
    private var browseSection: some View {
        if browseResults.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(browseResults) { movie in
                    MovieSuggestionRow(
                        movie: movie,
                        onRank: { logMovie = movie },
                        onOpen: { detailMovie = movie }
                    )
                    Divider()
                }
            }
        }
    }

    private func loadBrowse() async {
        guard let kind = browse else { return }
        browseResults = []
        var result: [Movie]
        switch kind {
        case .releases:
            result = (try? await TMDBService.shared.upcoming()) ?? []
            // Soonest first — it's a release calendar, not a chart.
            result.sort { ($0.releaseDateFull ?? "") < ($1.releaseDateFull ?? "") }
        case .popular:
            result = (try? await TMDBService.shared.popular()) ?? []
        case .trending:
            result = (try? await TMDBService.shared.trending()) ?? []
        }
        guard browse == kind else { return }   // user switched mid-flight
        browseResults = result
        for movie in result { store.cache(movie) }
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

    // MARK: Suggested for you (growth: follow lots of people fast)

    private var suggestedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !contactMatches.isEmpty {
                Text("FROM YOUR CONTACTS")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.gray)
                    .padding(.top, 4)
                ForEach(contactMatches) { member in
                    suggestedRow(member, reason: "In your contacts")
                    Divider()
                }
            } else if !contactsChecked {
                Button {
                    Task { await findContacts() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.title3)
                            .foregroundStyle(Theme.marquee)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Find friends from contacts")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            Text("See who you know on Cini — contacts never leave this check")
                                .font(.caption)
                                .foregroundStyle(Theme.gray)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.gray)
                    }
                    .padding(12)
                }
                .buttonStyle(.plain)
                .floatingCard(cornerRadius: 14)
                .padding(.vertical, 6)
            } else {
                // Checked but no matches — say so instead of vanishing.
                Text("None of your contacts are on Cini yet — invite them below.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 6)
            }

            Text("SUGGESTED FOR YOU")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.gray)
                .padding(.top, 10)
            if suggested.isEmpty {
                Text("Suggestions appear as more members join — invite your crew to get it going.")
                    .font(.caption)
                    .foregroundStyle(Theme.gray)
                    .padding(.vertical, 12)
            }
            ForEach(suggested) { member in
                suggestedRow(member, reason: suggestionReason(member))
                Divider()
            }

            Button {
                showInvite = true
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "paperplane.circle.fill")
                        .font(.title2)
                        .foregroundStyle(Theme.marquee)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Invite friends to Cini")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.ink)
                        Text("They enter your @username when they join — you follow each other automatically")
                            .font(.caption)
                            .foregroundStyle(Theme.gray)
                    }
                    Spacer()
                }
                .padding(12)
            }
            .buttonStyle(.plain)
            .floatingCard(cornerRadius: 14)
            .padding(.vertical, 10)
        }
        .sheet(isPresented: $showInvite) {
            InviteSheet()
                .presentationDetents([.medium])
        }
        .task {
            if suggested.isEmpty {
                suggested = (try? await SupabaseService.shared.suggestedMembers()) ?? []
            }
        }
    }

    private func suggestionReason(_ member: SuggestedMember) -> String {
        if let pct = member.matchPct, pct > 0 {
            return "\(Int(pct))% taste match · \(member.watched) films"
        }
        return member.watched > 0 ? "\(member.watched) films ranked" : "New here too"
    }

    private func suggestedRow(_ member: SuggestedMember, reason: String) -> some View {
        NavigationLink {
            MemberProfileView(userID: member.id, username: member.username)
        } label: {
            MemberRow(
                avatarURL: member.avatarUrl.flatMap(URL.init),
                title: member.displayName.isEmpty ? member.username : member.displayName,
                subtitle: reason,
                subtitleColor: Theme.scoreGreen
            ) {
                PillButton(title: followedFromSearch.contains(member.id) ? "Following" : "Follow",
                           style: followedFromSearch.contains(member.id) ? .outlined : .filled) {
                    Task {
                        if followedFromSearch.contains(member.id) {
                            followedFromSearch.remove(member.id)
                            try? await SupabaseService.shared.unfollow(member.id)
                        } else {
                            followedFromSearch.insert(member.id)
                            try? await SupabaseService.shared.follow(member.id)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func findContacts() async {
        contactsChecked = true
        let emails = await ContactsEmails.fetch()
        guard !emails.isEmpty else { return }
        contactMatches = (try? await SupabaseService.shared.membersFromEmails(emails)) ?? []
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(memberResults) { member in
                NavigationLink {
                    MemberProfileView(userID: member.id, username: member.username)
                } label: {
                    MemberRow(
                        avatarURL: member.avatarUrl.flatMap(URL.init),
                        title: member.displayName.isEmpty ? member.username : member.displayName,
                        subtitle: "@\(member.username)"
                    ) {
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

    /// Popular-title suggestions for cold start. Imported titles waiting to
    /// be ranked live in Your Lists → Watched → Pending, not here.
    private var visibleMaybeSeen: [Movie] {
        maybeSeen.filter { !dismissedMaybeSeen.contains($0.tmdbID) && !store.isWatched($0.tmdbID) }
    }

    private var maybeSeenSection: some View {
        popularFallbackSection
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
            isSearching = true
            defer { isSearching = false }
            if tab == 0 {
                // Genre and director queries are first-class: "horror"
                // fills with the genre's most popular, "nolan" with his
                // filmography — both lead the title matches.
                async let genreTask: [Movie] = {
                    guard let genreID = TMDBService.genreID(matching: text) else { return [] }
                    return (try? await TMDBService.shared.popular(genreID: genreID)) ?? []
                }()
                async let directorTask: [Movie] = text.count >= 4
                    ? ((try? await TMDBService.shared.directedMovies(matching: text)) ?? [])
                    : []
                var results = (try? await TMDBService.shared.search(query: text, year: nil)) ?? []
                // Subtitle queries ("new hope") match famous films via
                // their alternative titles, but TMDB buries them on page 2.
                // When page 1 has no notable title, pull the next page so
                // the popularity ranking below can rescue them.
                if results.map({ $0.popularity ?? 0 }).max() ?? 0 < 5, results.count >= 15 {
                    let more = (try? await TMDBService.shared.search(query: text, year: nil, page: 2)) ?? []
                    for movie in more where !results.contains(where: { $0.tmdbID == movie.tmdbID }) {
                        results.append(movie)
                    }
                }
                // TMDB goes blank on typos — retry with progressively
                // trimmed input, then the longest word on its own.
                if results.count < 3, text.count > 3 {
                    var attempts: [String] = []
                    var trimmed = text
                    for _ in 0..<2 where trimmed.count > 3 {
                        trimmed = String(trimmed.dropLast())
                        attempts.append(trimmed)
                    }
                    if let longest = text.split(separator: " ").max(by: { $0.count < $1.count }),
                       longest.count > 3, String(longest) != text {
                        attempts.append(String(longest))
                    }
                    for attempt in attempts where results.count < 5 {
                        guard !Task.isCancelled else { return }
                        let more = (try? await TMDBService.shared.search(query: attempt, year: nil)) ?? []
                        for movie in more where !results.contains(where: { $0.tmdbID == movie.tmdbID }) {
                            results.append(movie)
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                // Title similarity and popularity in roughly equal measure:
                // big films win loose queries ("new hope" -> Star Wars, pop
                // 27 vs 0.5) while typo-corrected and exact matches still
                // top their own searches. Weights validated against live
                // TMDB data for all three cases.
                if results.count > 1 {
                    let needle = text.lowercased().trimmingCharacters(in: .whitespaces)
                    func rank(_ movie: Movie) -> Double {
                        var similarity = Fuzzy.similarity(query: text, candidate: movie.title)
                        if movie.title.lowercased().contains(needle) {
                            similarity = max(similarity, 0.82)
                        }
                        return 0.5 * similarity + 0.6 * min(movie.popularity ?? 0, 30) / 30
                    }
                    results.sort { rank($0) > rank($1) }
                }
                // Director matches lead, then the genre's most popular,
                // then title matches — deduped.
                let special = (await directorTask) + (await genreTask)
                if !special.isEmpty {
                    var merged: [Movie] = []
                    var seen = Set<Int>()
                    for movie in special + results where seen.insert(movie.tmdbID).inserted {
                        merged.append(movie)
                    }
                    results = merged
                }
                guard !Task.isCancelled else { return }
                movieResults = results
                for movie in movieResults { store.cache(movie) }
            } else {
                let found = (try? await SupabaseService.shared.searchMembers(query: text)) ?? []
                guard !Task.isCancelled else { return }
                memberResults = found
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
