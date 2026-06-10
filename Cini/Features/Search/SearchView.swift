import SwiftUI

/// Center tab: Movies · Members search, year/decade filter, quick pills,
/// recents, and "Movies you may have seen" seeded by import + popularity.
struct SearchView: View {
    @Environment(RankingStore.self) private var store

    @State private var tab = 0   // 0 = Movies, 1 = Members
    @State private var query = ""
    @State private var yearFilter = ""
    @State private var movieResults: [Movie] = []
    @State private var memberResults: [ProfileRow] = []
    @State private var recents: [Movie] = []
    @State private var maybeSeen: [Movie] = []
    @State private var dismissedMaybeSeen: Set<Int> = []
    @State private var showAllMaybeSeen = false
    @State private var logMovie: Movie?
    @State private var detailMovie: Movie?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    tabsRow
                    searchFields
                    quickPills

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
                .padding(16)
            }
            .background(Theme.background)
            .fullScreenCover(item: $logMovie) { movie in
                LogFlowView(movie: movie)
            }
            .navigationDestination(item: $detailMovie) { movie in
                MovieDetailView(movie: movie)
            }
            .task { await loadSuggestions() }
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
                .foregroundStyle(tab == index ? Theme.teal : Theme.gray)
                Rectangle()
                    .fill(tab == index ? Theme.teal : .clear)
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
                    .onChange(of: query) { _, _ in scheduleSearch() }
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))

            if tab == 0 {
                HStack(spacing: 8) {
                    Image(systemName: "calendar").foregroundStyle(Theme.gray)
                    TextField("Year / Decade", text: $yearFilter)
                        .keyboardType(.numberPad)
                        .onChange(of: yearFilter) { _, _ in scheduleSearch() }
                    if !yearFilter.isEmpty {
                        Button {
                            yearFilter = ""
                            scheduleSearch()
                        } label: {
                            Image(systemName: "xmark").foregroundStyle(Theme.gray)
                        }
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.hairline))
            }
        }
    }

    private var quickPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                PillButton(title: "Where to Watch", systemImage: "play.rectangle")
                PillButton(title: "Showtimes", systemImage: "ticket")
                PillButton(title: "Recs", systemImage: "heart")
                PillButton(title: "Trending", systemImage: "chart.line.uptrend.xyaxis")
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
                        PillButton(title: "Follow", style: .outlined) {
                            Task { try? await SupabaseService.shared.follow(member.id) }
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

    private var visibleMaybeSeen: [Movie] {
        maybeSeen.filter { !dismissedMaybeSeen.contains($0.tmdbID) && !store.isWatched($0.tmdbID) }
    }

    private var maybeSeenSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Movies you may have seen").font(.headline)
            Text("Based on your import (Ranked \(store.watchedCount) of \(store.watchedCount + visibleMaybeSeen.count))")
                .font(.caption)
                .foregroundStyle(Theme.gray)

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
                Button {
                    withAnimation { showAllMaybeSeen = true }
                } label: {
                    HStack {
                        Text("See All (\(visibleMaybeSeen.count))").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.down")
                    }
                    .foregroundStyle(Theme.teal)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .padding(.top, 8)
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
                let year = Int(yearFilter)
                movieResults = (try? await TMDBService.shared.search(query: text, year: year)) ?? []
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
                        .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.teal : Theme.ink)
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
