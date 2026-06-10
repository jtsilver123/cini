import Foundation
import Observation
import RankingEngine

/// Source of truth for the signed-in user's ranked list and watchlist.
/// Wraps the pure RankingEngine and mirrors every mutation to Supabase via
/// the atomic RPCs. UI binds to this; the engine never touches the network.
@Observable
@MainActor
final class RankingStore {
    private(set) var list = RankingList<Int>()
    private(set) var movies: [Int: Movie] = [:]          // metadata cache
    private(set) var watchlist: [WatchlistItem] = []
    private(set) var isLoaded = false

    private let supabase: SupabaseService
    private let tmdb: TMDBService

    init(supabase: SupabaseService = .shared, tmdb: TMDBService = .shared) {
        self.supabase = supabase
        self.tmdb = tmdb
    }

    // MARK: - Loading

    func load() async {
        guard let userID = supabase.currentUserID else { return }
        do {
            async let rankingRows = supabase.rankings(userID: userID)
            async let watchlistRows = supabase.watchlist(userID: userID)
            let (rankings, watching) = try await (rankingRows, watchlistRows)

            let items = rankings.compactMap { row -> RankedItem<Int>? in
                guard let sentiment = Sentiment(rawValue: row.bucket) else { return nil }
                return RankedItem(id: row.movieId, sentiment: sentiment)
            }
            list = RankingList(items: items)
            watchlist = watching.map {
                WatchlistItem(id: $0.id, userID: $0.userId, movieID: $0.movieId, createdAt: $0.createdAt)
            }

            let allIDs = Set(rankings.map(\.movieId) + watching.map(\.movieId))
            let rows = try await supabase.movies(ids: Array(allIDs))
            for row in rows { movies[row.tmdbId] = row.asMovie }
            isLoaded = true
        } catch {
            assertionFailure("RankingStore.load failed: \(error)")
        }
    }

    // MARK: - Reading

    var watchedItems: [ScoredItem<Int>] { list.scoredItems }
    var watchedCount: Int { list.count }
    var watchlistCount: Int { watchlist.count }

    func movie(_ id: Int) -> Movie? { movies[id] }
    func isWatched(_ movieID: Int) -> Bool { list.contains(movieID) }
    func isOnWatchlist(_ movieID: Int) -> Bool { watchlist.contains { $0.movieID == movieID } }
    func scoredItem(for movieID: Int) -> ScoredItem<Int>? { list.scoredItem(for: movieID) }

    /// Watched items logged in `year`, for the annual challenge card.
    func challengeProgress(year: Int, rankingDates: [Int: Date] = [:]) -> Int {
        // v1 approximation: count of all watched; refined when watch dates sync.
        watchedCount
    }

    // MARK: - Log flow

    func beginSession(movie: Movie, sentiment: Sentiment) -> InsertionSession<Int> {
        cache(movie)
        if list.contains(movie.tmdbID) {
            return list.beginReranking(of: movie.tmdbID, sentiment: sentiment)
        }
        return list.beginInsertion(of: movie.tmdbID, sentiment: sentiment)
    }

    /// Commit locally and mirror to the rank_insert RPC.
    @discardableResult
    func commit(_ session: InsertionSession<Int>, watchDate: Date? = nil) async -> ScoredItem<Int>? {
        guard session.isComplete else { return nil }
        let scored = list.commit(session)
        watchlist.removeAll { $0.movieID == session.newItemID }
        do {
            if let movie = movies[session.newItemID] {
                try? await supabase.cacheMovie(movie)
            }
            _ = try await supabase.rankInsert(
                movieID: session.newItemID,
                bucket: session.sentiment,
                position: session.resolvedBucketPosition!,
                watchDate: watchDate
            )
        } catch {
            assertionFailure("rank_insert failed: \(error)")
        }
        return scored
    }

    func removeRanking(movieID: Int) async {
        list.remove(movieID)
        try? await supabase.rankRemove(movieID: movieID)
    }

    // MARK: - Watchlist

    func toggleWatchlist(movie: Movie) async {
        cache(movie)
        if let index = watchlist.firstIndex(where: { $0.movieID == movie.tmdbID }) {
            watchlist.remove(at: index)
        } else if let userID = supabase.currentUserID {
            watchlist.insert(
                WatchlistItem(id: UUID(), userID: userID, movieID: movie.tmdbID, createdAt: .now),
                at: 0
            )
        }
        try? await supabase.cacheMovie(movie)
        try? await supabase.watchlistToggle(movieID: movie.tmdbID)
    }

    // MARK: - Metadata

    func cache(_ movie: Movie) {
        // Keep the richer record if we already have details.
        if let existing = movies[movie.tmdbID], existing.runtimeMinutes != nil, movie.runtimeMinutes == nil {
            return
        }
        movies[movie.tmdbID] = movie
    }

    /// Fill in detail fields (runtime, certification, director, providers)
    /// for a movie we only know from search results.
    func enrich(_ movieID: Int) async {
        guard movies[movieID]?.runtimeMinutes == nil else { return }
        guard var detailed = try? await tmdb.details(for: movieID) else { return }
        if let providers = try? await tmdb.watchProviders(for: movieID) {
            detailed.streamingOn = providers.streamingNames
        }
        movies[movieID] = detailed
        try? await supabase.cacheMovie(detailed)
    }
}
