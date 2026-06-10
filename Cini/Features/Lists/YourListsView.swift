import SwiftUI
import RankingEngine

/// "MY LISTS": category switcher, Watched/Watchlist/Recs/Guides sub-tabs,
/// filter pills, sort control, ranked rows, and the floating View Timeline pill.
struct YourListsView: View {
    @Environment(RankingStore.self) private var store

    @State private var category: MediaCategory = .movies
    @State private var showCategorySheet = false
    @State private var subTab: SubTab = .watched
    @State private var sortDescending = true
    @State private var genreFilter: String?
    @State private var decadeFilter: Int?
    @State private var showTimeline = false
    @State private var detailMovie: Movie?
    @State private var logMovie: Movie?
    @State private var recs: [Movie] = []

    enum SubTab: String, CaseIterable {
        case watched = "Watched"
        case watchlist = "Watchlist"
        case recs = "Recs"
        case guides = "Guides"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                categoryRow
                subTabs
                filterRow
                sortRow
                listContent
            }
            .background(Theme.background)
            .overlay(alignment: .bottom) {
                PillButton(title: "View Timeline", systemImage: "chart.bar.xaxis") {
                    showTimeline = true
                }
                .padding(.bottom, 18)
            }
            .sheet(isPresented: $showCategorySheet) {
                CategorySheet(selection: $category)
                    .presentationDetents([.height(260)])
            }
            .sheet(isPresented: $showTimeline) {
                TimelineView()
            }
            .sheet(item: $logMovie) { movie in
                LogFlowView(movie: movie)
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
                Image(systemName: "square.and.arrow.up")
                Image(systemName: "ellipsis")
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
                            Text(tab.rawValue)
                                .font(.subheadline.weight(subTab == tab ? .bold : .regular))
                                .foregroundStyle(subTab == tab ? Theme.ink : Theme.gray)
                            Rectangle()
                                .fill(subTab == tab ? Theme.ink : .clear)
                                .frame(height: 2)
                        }
                        .fixedSize()
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 3) {
                    Text("More").foregroundStyle(Theme.gray)
                    Image(systemName: "chevron.down").font(.caption2).foregroundStyle(Theme.gray)
                }
                .font(.subheadline)
            }
            .padding(.horizontal, 16)
        }
        .padding(.top, 10)
    }

    private var filterRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {} label: {
                    Image(systemName: "line.3.horizontal.decrease")
                        .padding(10)
                        .foregroundStyle(Theme.ink)
                }
                .buttonStyle(.plain)
                .glassCapsule()

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
                FilterPill(title: "Streaming")
                FilterPill(title: "Runtime", hasChevron: false)
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
                .foregroundStyle(Theme.teal)
            }
            .buttonStyle(.plain)
            Spacer()
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.ink)
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
        case .guides: guidesPlaceholder
        }
    }

    private var filteredWatched: [ScoredItem<Int>] {
        let items = sortDescending ? store.watchedItems : store.watchedItems.reversed()
        return items.filter { item in
            guard let movie = store.movie(item.id) else { return true }
            if movie.mediaKind != category.mediaKind && !(category == .movies && movie.mediaKind == "movie") {
                return false
            }
            if let genreFilter, !movie.genres.contains(genreFilter) { return false }
            if let decadeFilter, let year = movie.releaseYear, !(decadeFilter..<decadeFilter + 10).contains(year) {
                return false
            }
            return true
        }
    }

    private var watchedList: some View {
        List {
            ForEach(filteredWatched, id: \.id) { item in
                if let movie = store.movie(item.id) {
                    WatchedRowView(rank: item.rank, movie: movie, score: item.score)
                        .contentShape(Rectangle())
                        .onTapGesture { detailMovie = movie }
                        .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.watchedItems.isEmpty {
                emptyList("Log your first movie with the + tab.")
            }
        }
    }

    private var watchlistList: some View {
        List {
            ForEach(store.watchlist) { item in
                if let movie = store.movie(item.movieID) {
                    WatchlistRowView(movie: movie) {
                        logMovie = movie
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { detailMovie = movie }
                    .listRowBackground(Theme.background)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.watchlist.isEmpty {
                emptyList("Bookmark movies you want to watch.")
            }
        }
    }

    private var recsList: some View {
        List {
            ForEach(recs) { movie in
                WatchlistRowView(movie: movie) {
                    logMovie = movie
                }
                .contentShape(Rectangle())
                .onTapGesture { detailMovie = movie }
                .listRowBackground(Theme.background)
            }
        }
        .listStyle(.plain)
        .task {
            // Personalized recs: TMDB similar-titles seeded by the user's
            // top-ranked movies (friend-weighted recs land with taste graph).
            guard recs.isEmpty, let top = store.watchedItems.first else {
                if recs.isEmpty { recs = (try? await TMDBService.shared.trending()) ?? [] }
                return
            }
            let similar = (try? await TMDBService.shared.similar(to: top.id)) ?? []
            recs = similar.filter { !store.isWatched($0.tmdbID) }
        }
    }

    private var guidesPlaceholder: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "book").font(.largeTitle).foregroundStyle(Theme.gray)
            Text("Guides are coming soon")
                .font(.subheadline)
                .foregroundStyle(Theme.gray)
            Spacer()
        }
        .frame(maxWidth: .infinity)
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
    var onQuickRank: () -> Void = {}

    @Environment(RankingStore.self) private var store
    @State private var community: CommunityScore?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
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
                            .foregroundStyle(store.isOnWatchlist(movie.tmdbID) ? Theme.teal : Theme.ink)
                    }
                }
                .font(.title3)
                .buttonStyle(.plain)
                .padding(.top, 6)
            }
            Spacer()
            if let community {
                ScoreBadge(score: community.avgScore, count: community.ratingCount)
            }
        }
        .padding(.vertical, 6)
        .task {
            community = try? await SupabaseService.shared.communityScore(movieID: movie.tmdbID)
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
                        .foregroundStyle(selection == category ? .white : Theme.ink)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(selection == category ? Theme.teal : .clear)
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

// MARK: - View Timeline (Beli's View Map → decade/year breakdown)

struct TimelineView: View {
    @Environment(RankingStore.self) private var store

    private var decadeCounts: [(decade: Int, count: Int)] {
        var counts: [Int: Int] = [:]
        for item in store.watchedItems {
            if let year = store.movie(item.id)?.releaseYear {
                counts[year / 10 * 10, default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Your watched list by decade")
                        .font(.subheadline)
                        .foregroundStyle(Theme.gray)

                    let maxCount = decadeCounts.map(\.count).max() ?? 1
                    ForEach(decadeCounts, id: \.decade) { entry in
                        HStack(spacing: 12) {
                            Text("\(String(entry.decade))s")
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 56, alignment: .leading)
                            GeometryReader { geo in
                                Capsule()
                                    .fill(Theme.teal)
                                    .frame(width: max(8, geo.size.width * CGFloat(entry.count) / CGFloat(maxCount)))
                            }
                            .frame(height: 18)
                            Text("\(entry.count)")
                                .font(.subheadline)
                                .foregroundStyle(Theme.gray)
                        }
                    }

                    if decadeCounts.isEmpty {
                        Text("Rank some movies to see your timeline.")
                            .foregroundStyle(Theme.gray)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Timeline")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
