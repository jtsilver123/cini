import Foundation
import Observation
import RankingEngine

/// Source of truth for the signed-in user's ranked list and watchlist.
/// Wraps the pure RankingEngine and mirrors every mutation to Supabase via
/// the atomic RPCs. UI binds to this; the engine never touches the network.
@Observable
@MainActor
final class RankingStore {
    /// One ranked list per media kind — movies and TV are ranked
    /// SEPARATELY and never compared head-to-head. Keys: "movie", "tv".
    /// Each kind has its own buckets, positions, scores, and #1.
    private(set) var lists: [String: RankingList<Int>] = ["movie": RankingList(), "tv": RankingList()]
    /// Scored snapshot of both lists (movies then TV), recomputed only when a
    /// list mutates — reading rankings is hot (every list render, chat
    /// context), scoring a few hundred items on each read is not free. Each
    /// item's rank/score is within its own media kind.
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

    /// Wipe in-memory state on sign-out so the next account starts clean: no
    /// stale rankings bleeding into a new account's UI, and — critically —
    /// `isLoaded` flips back to false so onboarding re-evaluates from scratch
    /// (a new signup must not inherit the previous account's watched count and
    /// skip onboarding).
    func reset() {
        lists = ["movie": RankingList(), "tv": RankingList()]
        watchedItems = []
        movies = [:]
        watchlist = []
        predictedScores = [:]
        customLists = []
        isLoaded = false
    }

    func load() async {
        guard let userID = supabase.currentUserID else { return }
        // Cold start: the last-synced snapshot renders lists instantly
        // while the fresh data loads (same idea as FeedDiskCache).
        if !isLoaded, let snapshot = RankingDiskCache.load(for: userID) {
            lists = snapshot.lists
            watchlist = snapshot.watchlist
            movies = snapshot.movies
            listChanged()
            isLoaded = true
        }
        do {
            async let rankingRows = supabase.rankings(userID: userID)
            async let watchlistRows = supabase.watchlist(userID: userID)
            let (rankings, watching) = try await (rankingRows, watchlistRows)

            watchlist = watching.map {
                WatchlistItem(id: $0.id, userID: $0.userId, movieID: $0.movieId,
                              createdAt: $0.createdAt, note: $0.note, watchBy: $0.watchBy)
            }

            // Movies must be known before partitioning rankings, since the
            // media kind that splits the two lists lives on the movie row.
            let allIDs = Set(rankings.map(\.movieId) + watching.map(\.movieId))
            let rows = try await supabase.movies(ids: Array(allIDs))
            for row in rows { movies[row.tmdbId] = row.asMovie }

            lists = buildLists(from: rankings)
            listChanged()
            isLoaded = true
            RankingDiskCache.save(.init(userID: userID, lists: lists,
                                        watchlist: watchlist, movies: movies))
            // Fire-and-forget: warm the Want to Watch Rec Scores so the
            // Lists tab opens with badges already in place.
            Task { await refreshPredictedScores() }
            Task { await refreshCustomLists() }
        } catch {
            // Don't fail silently: in release `assertionFailure` is a no-op, and
            // a swallowed load here can strand a user on a blank app (onboarding
            // gates on `isLoaded`). Log it, and if we have no snapshot to fall
            // back on, tell them so they can retry instead of staring at nothing.
            assertionFailure("RankingStore.load failed: \(error)")
            SupabaseService.logSwallowed("RankingStore.load", error)
            if !isLoaded {
                ToastCenter.shared.show("Couldn't load your library — pull to refresh.")
            }
        }
    }

    /// Split the server's rankings into per-kind lists. Positions already
    /// come back scoped per media kind (migration 0043) and ordered by
    /// position, so filtering by kind preserves each list's order.
    private func buildLists(from rankings: [RankingRow]) -> [String: RankingList<Int>] {
        var byKind: [String: [RankedItem<Int>]] = ["movie": [], "tv": []]
        for row in rankings {
            guard let sentiment = Sentiment(rawValue: row.bucket) else { continue }
            byKind[kindKey(forMovie: row.movieId), default: []]
                .append(RankedItem(id: row.movieId, sentiment: sentiment))
        }
        return ["movie": RankingList(items: byKind["movie"] ?? []),
                "tv": RankingList(items: byKind["tv"] ?? [])]
    }

    /// "movie" or "tv" — the key into `lists`. Anything not TV files as movie.
    private func kindKey(_ mediaKind: String?) -> String { mediaKind == "tv" ? "tv" : "movie" }
    /// Falls back to the id sign when metadata hasn't loaded — TV uses
    /// negative tmdb ids (TMDBService convention), so a missing movie row
    /// can't misfile a show into the movies list.
    private func kindKey(forMovie id: Int) -> String {
        if let kind = movies[id]?.mediaKind { return kindKey(kind) }
        return id < 0 ? "tv" : "movie"
    }

    func refreshPredictedScores() async {
        let scores = await supabase.predictedScores(movieIDs: watchlist.map(\.movieID))
        predictedScores.merge(scores) { _, new in new }
    }

    /// Fold freshly-fetched Rec Scores into the shared cache so every surface
    /// (lists, movie page) shows the SAME predicted value for a title.
    func mergePredicted(_ scores: [Int: Double]) {
        predictedScores.merge(scores) { _, new in new }
    }

    func refreshCustomLists() async {
        customLists = (try? await supabase.myLists()) ?? customLists
    }

    /// Create a list through the shared cache so EVERY surface (Lists
    /// tabs, the add-to-list picker) sees it immediately — not just the
    /// screen that made it.
    func createList(name: String, mediaKind: String) async -> CustomList? {
        guard let list = try? await supabase.createList(name: name, mediaKind: mediaKind) else {
            ToastCenter.shared.saveFailed()
            return nil
        }
        customLists.insert(list, at: 0)
        return list
    }

    /// Delete a list and reconcile the shared cache against the server,
    /// so every surface (Lists tabs, the add-to-list picker) agrees. The
    /// old per-screen optimistic deletes left phantom lists behind. False
    /// means it didn't stick (the caller should re-sync from the store).
    @discardableResult
    func deleteList(_ id: UUID) async -> Bool {
        do {
            try await supabase.deleteList(id)
            await refreshCustomLists()
            return true
        } catch {
            await refreshCustomLists()   // pull the truth back
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    /// Rename a list through the shared cache so every surface updates at
    /// once. Optimistic, with a reconcile + toast if the write misses.
    @discardableResult
    func renameList(_ id: UUID, to name: String) async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let previous = customLists
        if let i = customLists.firstIndex(where: { $0.id == id }) {
            customLists[i].name = trimmed
        }
        do {
            try await supabase.renameList(id, to: trimmed)
            Haptics.success()
            return true
        } catch {
            customLists = previous            // pull the truth back
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    // MARK: - Reading

    var watchedCount: Int { lists.values.reduce(0) { $0 + $1.count } }
    var watchlistCount: Int { watchlist.count }

    func movie(_ id: Int) -> Movie? { movies[id] }
    func isWatched(_ movieID: Int) -> Bool { lists.values.contains { $0.contains(movieID) } }
    func isOnWatchlist(_ movieID: Int) -> Bool { watchlist.contains { $0.movieID == movieID } }
    func scoredItem(for movieID: Int) -> ScoredItem<Int>? {
        watchedItems.first { $0.id == movieID }
    }

    /// Every list mutation funnels through here so the scored snapshot stays
    /// in lockstep. Movies first, then TV — each scored within its own kind.
    private func listChanged() {
        watchedItems = (lists["movie"]?.scoredItems ?? []) + (lists["tv"]?.scoredItems ?? [])
    }

    // MARK: - Log flow

    func beginSession(movie: Movie, sentiment: Sentiment) -> InsertionSession<Int> {
        cache(movie)
        // Compare only within this title's media kind — the opponents come
        // from that kind's bucket, so a movie never faces a TV show, and the
        // first movie (or first show) has an empty bucket → no comparisons.
        let key = kindKey(movie.mediaKind)
        var kindList = lists[key] ?? RankingList()
        let session = kindList.contains(movie.tmdbID)
            ? kindList.beginReranking(of: movie.tmdbID, sentiment: sentiment)
            : kindList.beginInsertion(of: movie.tmdbID, sentiment: sentiment)
        lists[key] = kindList
        listChanged()
        return session
    }

    /// Commit locally and mirror to the rank_insert RPC.
    @discardableResult
    func commit(_ session: InsertionSession<Int>, watchDate: Date? = nil,
                stealth: Bool = false) async -> ScoredItem<Int>? {
        guard session.isComplete else { return nil }
        guard let bucketPosition = session.resolvedBucketPosition else {
            // Engine state should make this impossible; never crash on it.
            ToastCenter.shared.saveFailed()
            return nil
        }
        let key = kindKey(forMovie: session.newItemID)
        var kindList = lists[key] ?? RankingList()
        let scored = kindList.commit(session)
        lists[key] = kindList
        listChanged()
        watchlist.removeAll { $0.movieID == session.newItemID }
        do {
            if let movie = movies[session.newItemID] {
                // rank_insert FKs onto movies — the cache isn't optional.
                try await supabase.cacheMovie(movie)
            }
            _ = try await supabase.rankInsert(
                movieID: session.newItemID,
                bucket: session.sentiment,
                position: bucketPosition,
                watchDate: watchDate,
                stealth: stealth
            )
        } catch {
            // One retry — a transient network blip shouldn't drop a rank.
            try? await Task.sleep(for: .seconds(1))
            do {
                if let movie = movies[session.newItemID] {
                    // rank_insert FKs onto movies — the cache isn't optional.
                    try await supabase.cacheMovie(movie)
                }
                _ = try await supabase.rankInsert(
                    movieID: session.newItemID,
                    bucket: session.sentiment,
                    position: bucketPosition,
                    watchDate: watchDate,
                    stealth: stealth
                )
            } catch {
                // Both attempts failed: resync from the server so we don't
                // celebrate a rank that only exists on-device. This is correct
                // for both paths — a first-time rank vanishes (the server never
                // got it) while a failed RE-rank is restored to its prior
                // position (the server still holds it); a blind local remove
                // would have deleted an existing rank. Returning nil tells the
                // log flow to show an error instead of the result ticket.
                await load()
                ToastCenter.shared.saveFailed()
                return nil
            }
        }
        // Server confirmed — now it's safe to clear it from the import queue
        // (doing this before the write would drop it from "pending to rate"
        // even if the rank failed and we reverted).
        ImportQueue.shared.markRanked(session.newItemID)
        // Tell friends who already love this title that you just rated it —
        // but never for a stealth rank, which must stay invisible to everyone.
        if !stealth {
            let ratedID = session.newItemID
            Task { await supabase.notifyFriendsOfRating(movieID: ratedID) }
        }
        return scored
    }

    /// Drag-to-reorder: rebuild the list in the new order. The moved item
    /// adopts its new neighborhood's sentiment (dragging into the loved
    /// block makes it loved), then the standard rank_insert RPC persists
    /// the move and rescores server-side.
    func moveRanked(kind: String, fromOffsets: IndexSet, toOffset: Int) async {
        let key = kindKey(kind)
        let current = lists[key]?.scoredItems ?? []
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

        let prior = lists[key]
        let items = ids.map {
            RankedItem(id: $0, sentiment: $0 == moving ? newSentiment : (sentimentOf[$0] ?? .fine))
        }
        lists[key] = RankingList(items: items)
        listChanged()

        let bucketPosition = ids[0..<to].filter {
            ($0 == moving ? newSentiment : sentimentOf[$0]) == newSentiment
        }.count
        do {
            _ = try await supabase.rankInsert(movieID: moving, bucket: newSentiment,
                                              position: bucketPosition)
        } catch {
            // The move didn't persist — restore the prior order rather than
            // let the next refresh silently undo it.
            if let prior { lists[key] = prior; listChanged() }
            ToastCenter.shared.saveFailed()
        }
    }

    /// Server-first: a delete that failed remotely must not vanish locally
    /// only to resurrect on the next refresh.
    @discardableResult
    func removeRanking(movieID: Int) async -> Bool {
        do {
            try await supabase.rankRemove(movieID: movieID)
            let key = kindKey(forMovie: movieID)
            var kindList = lists[key] ?? RankingList()
            kindList.remove(movieID)
            lists[key] = kindList
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
            // A satisfying confirm that the save stuck (only on add, not remove).
            if !wasSaved { Haptics.success() }
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

    /// Marking a show as "currently watching" supersedes Want to Watch — the
    /// `set_show_progress` RPC drops the watchlist row server-side. Mirror that
    /// in the shared cache so the bookmark and the Want to Watch list don't go
    /// stale. No network call: the RPC already did the delete.
    func watchlistSuperseded(movieID: Int) {
        watchlist.removeAll { $0.movieID == movieID }
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

    /// "Watch by" goal — local state plus the server row (nil clears it).
    func setWatchBy(movieID: Int, date: Date?) async {
        let iso = date.map { RankingStore.watchByFormatter.string(from: $0) }
        if let index = watchlist.firstIndex(where: { $0.movieID == movieID }) {
            watchlist[index].watchBy = iso
        }
        await supabase.setWatchBy(movieID: movieID, date: iso)
    }

    static let watchByFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

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
        do { try await supabase.cacheMovie(detailed) }
        catch { SupabaseService.logSwallowed("enrich_cache_movie", error) }
    }
}

/// Last-synced rankings + watchlist + metadata, persisted so a cold
/// launch renders Lists and the taste profile instantly instead of
/// blank-until-network. Refreshed after every successful load, cleared
/// at sign-out alongside FeedDiskCache.
enum RankingDiskCache {
    struct Snapshot: Codable {
        let userID: UUID
        let lists: [String: RankingList<Int>]
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
