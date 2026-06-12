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
    /// Scored snapshot of `list`, recomputed only when the list mutates —
    /// reading rankings is hot (every list render, chat context), scoring
    /// a few hundred items on each read is not free.
    private(set) var watchedItems: [ScoredItem<Int>] = []
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
        // Cold start: the last-synced snapshot renders lists instantly
        // while the fresh data loads (same idea as FeedDiskCache).
        if !isLoaded, let snapshot = RankingDiskCache.load(for: userID) {
            list = snapshot.list
            watchlist = snapshot.watchlist
            movies = snapshot.movies
            listChanged()
            isLoaded = true
        }
        do {
            async let rankingRows = supabase.rankings(userID: userID)
            async let watchlistRows = supabase.watchlist(userID: userID)
            let (rankings, watching) = try await (rankingRows, watchlistRows)

            let items = rankings.compactMap { row -> RankedItem<Int>? in
                guard let sentiment = Sentiment(rawValue: row.bucket) else { return nil }
                return RankedItem(id: row.movieId, sentiment: sentiment)
            }
            list = RankingList(items: items)
            listChanged()
            watchlist = watching.map {
                WatchlistItem(id: $0.id, userID: $0.userId, movieID: $0.movieId,
                              createdAt: $0.createdAt, note: $0.note)
            }

            let allIDs = Set(rankings.map(\.movieId) + watching.map(\.movieId))
            let rows = try await supabase.movies(ids: Array(allIDs))
            for row in rows { movies[row.tmdbId] = row.asMovie }
            isLoaded = true
            RankingDiskCache.save(.init(userID: userID, list: list,
                                        watchlist: watchlist, movies: movies))
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

    var watchedCount: Int { list.count }
    var watchlistCount: Int { watchlist.count }

    func movie(_ id: Int) -> Movie? { movies[id] }
    func isWatched(_ movieID: Int) -> Bool { list.contains(movieID) }
    func isOnWatchlist(_ movieID: Int) -> Bool { watchlist.contains { $0.movieID == movieID } }
    func scoredItem(for movieID: Int) -> ScoredItem<Int>? {
        watchedItems.first { $0.id == movieID }
    }

    /// Every list mutation funnels through here so the scored snapshot
    /// stays in lockstep.
    private func listChanged() {
        watchedItems = list.scoredItems
    }

    // MARK: - Log flow

    func beginSession(movie: Movie, sentiment: Sentiment) -> InsertionSession<Int> {
        cache(movie)
        if list.contains(movie.tmdbID) {
            let session = list.beginReranking(of: movie.tmdbID, sentiment: sentiment)
            listChanged()
            return session
        }
        return list.beginInsertion(of: movie.tmdbID, sentiment: sentiment)
    }

    /// Commit locally and mirror to the rank_insert RPC.
    @discardableResult
    func commit(_ session: InsertionSession<Int>, watchDate: Date? = nil) async -> ScoredItem<Int>? {
        guard session.isComplete else { return nil }
        guard let bucketPosition = session.resolvedBucketPosition else {
            // Engine state should make this impossible; never crash on it.
            ToastCenter.shared.saveFailed()
            return nil
        }
        let scored = list.commit(session)
        listChanged()
        watchlist.removeAll { $0.movieID == session.newItemID }
        ImportQueue.shared.markRanked(session.newItemID)
        do {
            if let movie = movies[session.newItemID] {
                // rank_insert FKs onto movies — the cache isn't optional.
                try await supabase.cacheMovie(movie)
            }
            _ = try await supabase.rankInsert(
                movieID: session.newItemID,
                bucket: session.sentiment,
                position: bucketPosition,
                watchDate: watchDate
            )
        } catch {
            // One retry — a transient network blip shouldn't drop a rank.
            try? await Task.sleep(for: .seconds(1))
            do {
                _ = try await supabase.rankInsert(
                    movieID: session.newItemID,
                    bucket: session.sentiment,
                    position: bucketPosition,
                    watchDate: watchDate
                )
            } catch {
                // Both attempts failed: the rank lives locally but not on
                // the server, so the next refresh would drop it. Say so.
                ToastCenter.shared.saveFailed()
            }
        }
        return scored
    }

    /// Drag-to-reorder: rebuild the list in the new order. The moved item
    /// adopts its new neighborhood's sentiment (dragging into the loved
    /// block makes it loved), then the standard rank_insert RPC persists
    /// the move and rescores server-side.
    func moveRanked(fromOffsets: IndexSet, toOffset: Int) async {
        let current = watchedItems
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
        listChanged()

        let bucketPosition = ids[0..<to].filter {
            ($0 == moving ? newSentiment : sentimentOf[$0]) == newSentiment
        }.count
        _ = try? await supabase.rankInsert(movieID: moving, bucket: newSentiment,
                                           position: bucketPosition)
    }

    /// Server-first: a delete that failed remotely must not vanish locally
    /// only to resurrect on the next refresh.
    @discardableResult
    func removeRanking(movieID: Int) async -> Bool {
        do {
            try await supabase.rankRemove(movieID: movieID)
            list.remove(movieID)
            listChanged()
            // The 'ranked' feed event points at a rating that no longer
            // exists — pull it too.
            try? await supabase.hideRankEvent(movieID: movieID)
            return true
        } catch {
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    // MARK: - Watchlist

    func toggleWatchlist(movie: Movie) async {
        cache(movie)
        Haptics.tap()
        let wasSaved: Bool
        var removedItem: WatchlistItem?
        if let index = watchlist.firstIndex(where: { $0.movieID == movie.tmdbID }) {
            wasSaved = true
            removedItem = watchlist[index]
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
        do {
            // Adding requires the movie row to exist — a failed cache means
            // the toggle would hit the FK, so it fails the whole save.
            if !wasSaved { try await supabase.cacheMovie(movie) }
            _ = try await supabase.watchlistToggle(movieID: movie.tmdbID)
        } catch {
            // Revert the optimistic flip and say so — silence feels broken.
            if wasSaved, let original = removedItem {
                // Restore the EXACT item (id, date, note) — a fresh stand-in
                // would drift from the server row it still mirrors.
                watchlist.insert(original, at: 0)
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

    /// "Why I saved this" — local state plus the server row.
    func setWatchlistNote(movieID: Int, note: String) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = watchlist.firstIndex(where: { $0.movieID == movieID }) {
            watchlist[index].note = trimmed.isEmpty ? nil : trimmed
        }
        await supabase.setWatchlistNote(movieID: movieID, note: trimmed)
    }

    /// The save popup lets users fix a mislabeled kind (TV movie,
    /// miniseries) — applied directly so the richer-record rule in
    /// cache() can't swallow it.
    func overrideMediaKind(_ movieID: Int, kind: String) {
        guard var existing = movies[movieID], existing.mediaKind != kind else { return }
        existing.mediaKind = kind
        movies[movieID] = existing
    }

    /// IDs with an enrich in flight, so concurrent rows asking for the
    /// same movie don't each hit TMDB.
    @ObservationIgnored private var enriching: Set<Int> = []

    /// Fill in detail fields (runtime, certification, director, providers)
    /// for a movie we only know from search results.
    func enrich(_ movieID: Int) async {
        guard movies[movieID]?.runtimeMinutes == nil, !enriching.contains(movieID) else { return }
        enriching.insert(movieID)
        defer { enriching.remove(movieID) }
        async let detailsTask = tmdb.details(for: movieID)
        async let providersTask = tmdb.watchProviders(for: movieID)
        guard var detailed = try? await detailsTask else { return }
        // A user's kind override (TV movie, miniseries) survives
        // enrichment — TMDB's label must not quietly undo it.
        if let kind = movies[movieID]?.mediaKind {
            detailed.mediaKind = kind
        }
        if let providers = try? await providersTask {
            detailed.streamingOn = providers.streamingNames
        }
        movies[movieID] = detailed
        try? await supabase.cacheMovie(detailed)
    }
}

/// Last-synced rankings + watchlist + metadata, persisted so a cold
/// launch renders Lists and the taste profile instantly instead of
/// blank-until-network. Refreshed after every successful load, cleared
/// at sign-out alongside FeedDiskCache.
enum RankingDiskCache {
    struct Snapshot: Codable {
        let userID: UUID
        let list: RankingList<Int>
        let watchlist: [WatchlistItem]
        let movies: [Int: Movie]
    }

    private static var url: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("rankings-cache.json")
    }

    static func load(for userID: UUID) -> Snapshot? {
        guard let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.userID == userID else { return nil }
        return snapshot
    }

    static func save(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: url, options: .atomic)
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
    }
}
