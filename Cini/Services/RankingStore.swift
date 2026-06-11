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
    /// Rec Scores for the watchlist, prefetched in the background at
    /// launch so Want to Watch renders its badges instantly.
    private(set) var predictedScores: [Int: Double] = [:]
    /// The user's custom lists — cached so a bookmark tap can decide
    /// instantly whether to offer a destination chooser.
    private(set) var customLists: [CustomList] = []
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
            // Fire-and-forget: warm the Want to Watch Rec Scores so the
            // Lists tab opens with badges already in place.
            Task { await refreshPredictedScores() }
            Task { await refreshCustomLists() }
        } catch {
            assertionFailure("RankingStore.load failed: \(error)")
        }
    }

    func refreshPredictedScores() async {
        let scores = await supabase.predictedScores(movieIDs: watchlist.map(\.movieID))
        predictedScores.merge(scores) { _, new in new }
    }

    func refreshCustomLists() async {
        customLists = (try? await supabase.myLists()) ?? customLists
    }

    // MARK: - Reading

    var watchedItems: [ScoredItem<Int>] { list.scoredItems }
    var watchedCount: Int { list.count }
    var watchlistCount: Int { watchlist.count }

    func movie(_ id: Int) -> Movie? { movies[id] }
    func isWatched(_ movieID: Int) -> Bool { list.contains(movieID) }
    func isOnWatchlist(_ movieID: Int) -> Bool { watchlist.contains { $0.movieID == movieID } }
    func scoredItem(for movieID: Int) -> ScoredItem<Int>? { list.scoredItem(for: movieID) }

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
        ImportQueue.shared.markRanked(session.newItemID)
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
            // One retry — a transient network blip shouldn't drop a rank.
            try? await Task.sleep(for: .seconds(1))
            _ = try? await supabase.rankInsert(
                movieID: session.newItemID,
                bucket: session.sentiment,
                position: session.resolvedBucketPosition!,
                watchDate: watchDate
            )
        }
        return scored
    }

    /// Drag-to-reorder: rebuild the list in the new order. The moved item
    /// adopts its new neighborhood's sentiment (dragging into the loved
    /// block makes it loved), then the standard rank_insert RPC persists
    /// the move and rescores server-side.
    func moveRanked(fromOffsets: IndexSet, toOffset: Int) async {
        let current = list.scoredItems
        guard let from = fromOffsets.first, current.indices.contains(from) else { return }
        var ids = current.map(\.id)
        let sentimentOf = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.sentiment) })

        let moving = ids.remove(at: from)
        let to = min(toOffset > from ? toOffset - 1 : toOffset, ids.count)
        ids.insert(moving, at: to)

        var newSentiment = sentimentOf[moving] ?? .fine
        if to > 0, let prev = sentimentOf[ids[to - 1]] {
            newSentiment = prev
        } else if to + 1 < ids.count, let next = sentimentOf[ids[to + 1]] {
            newSentiment = next
        }

        let items = ids.map {
            RankedItem(id: $0, sentiment: $0 == moving ? newSentiment : (sentimentOf[$0] ?? .fine))
        }
        list = RankingList(items: items)

        let bucketPosition = ids[0..<to].filter {
            ($0 == moving ? newSentiment : sentimentOf[$0]) == newSentiment
        }.count
        _ = try? await supabase.rankInsert(movieID: moving, bucket: newSentiment,
                                           position: bucketPosition)
    }

    func removeRanking(movieID: Int) async {
        list.remove(movieID)
        try? await supabase.rankRemove(movieID: movieID)
    }

    // MARK: - Watchlist

    func toggleWatchlist(movie: Movie) async {
        cache(movie)
        Haptics.tap()
        let wasSaved: Bool
        if let index = watchlist.firstIndex(where: { $0.movieID == movie.tmdbID }) {
            wasSaved = true
            watchlist.remove(at: index)
        } else if let userID = supabase.currentUserID {
            wasSaved = false
            watchlist.insert(
                WatchlistItem(id: UUID(), userID: userID, movieID: movie.tmdbID, createdAt: .now),
                at: 0
            )
        } else {
            return
        }
        try? await supabase.cacheMovie(movie)
        do {
            _ = try await supabase.watchlistToggle(movieID: movie.tmdbID)
        } catch {
            // Revert the optimistic flip and say so — silence feels broken.
            if wasSaved, let userID = supabase.currentUserID {
                watchlist.insert(
                    WatchlistItem(id: UUID(), userID: userID, movieID: movie.tmdbID, createdAt: .now),
                    at: 0
                )
            } else {
                watchlist.removeAll { $0.movieID == movie.tmdbID }
            }
            ToastCenter.shared.saveFailed()
        }
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
