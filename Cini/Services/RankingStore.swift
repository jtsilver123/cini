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
    private(set) var watchedItems: [ScoredItem<Int>] = [] {
        // uniquing defensively: a transient duplicate id (mid kind-flip)
        // must never crash the index rebuild.
        didSet { scoredByID = Dictionary(watchedItems.map { ($0.id, $0) },
                                         uniquingKeysWith: { first, _ in first }) }
    }
    /// O(1) score lookups — sort comparators over 1,500 titles were doing a
    /// linear scan PER COMPARISON without this.
    private(set) var scoredByID: [Int: ScoredItem<Int>] = [:]
    private(set) var movies: [Int: Movie] = [:]          // metadata cache
    private(set) var watchlist: [WatchlistItem] = [] {
        didSet { watchlistIDs = Set(watchlist.map(\.movieID)) }
    }
    /// O(1) membership — poster quick-actions ask "is this saved?" two or
    /// three times per artwork, on every render, everywhere.
    private(set) var watchlistIDs: Set<Int> = []
    /// movieID → when it was ranked, for the Watched list's "Date added" sort.
    private(set) var rankedAt: [Int: Date] = [:]
    /// Rec Scores for the watchlist, prefetched in the background at
    /// launch so Want to Watch renders its badges instantly.
    private(set) var predictedScores: [Int: Double] = [:]
    /// The user's custom lists — cached so a bookmark tap can decide
    /// instantly whether to offer a destination chooser.
    private(set) var customLists: [CustomList] = []
    /// Bumped whenever a title is added to a custom list, so an open list tab
    /// can re-fetch its contents even when the add happened from another screen
    /// (a movie page, Chat) — otherwise the open tab would show stale contents
    /// until you switched away and back.
    private(set) var listsRevision = 0
    private(set) var isLoaded = false

    /// The kind list as it stood when the current log-flow session began —
    /// restored if the commit's server write fails, since a re-rank has
    /// already removed the entry by then (see `beginSession`/`commit`).
    private var preSessionList: (key: String, movieID: Int, list: RankingList<Int>)?

    private let supabase: SupabaseService
    private let tmdb: TMDBService

    /// The app's live store, for entry points outside the SwiftUI environment
    /// (Siri intents) whose server writes must keep the shared cache coherent.
    /// Set by AppSession at bootstrap.
    static weak var current: RankingStore?

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
        rankedAt = [:]
        predictedScores = [:]
        customLists = []
        preSessionList = nil
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
            // Heal any row the movies table doesn't know (saved via a path
            // that skipped the cache): without metadata the title is
            // invisible to category tabs and counts drift — the #1 "my
            // Want to Watch count is off" report. Bounded fan-out.
            let missing = allIDs.filter { movies[$0] == nil }
            if !missing.isEmpty {
                await withTaskGroup(of: Movie?.self) { group in
                    var iterator = missing.makeIterator()
                    func addNext() {
                        guard let id = iterator.next() else { return }
                        group.addTask { try? await TMDBService.shared.details(for: id) }
                    }
                    for _ in 0..<6 { addNext() }
                    for await movie in group {
                        addNext()
                        guard let movie else { continue }
                        movies[movie.tmdbID] = movie
                        // Server-side too, so every future load has it.
                        try? await supabase.cacheMovie(movie)
                    }
                }
            }

            lists = buildLists(from: rankings)
            // When each title was ranked — powers the "Date added" sort on the
            // Watched list (the scored items themselves carry no timestamp).
            rankedAt = Dictionary(rankings.map { ($0.movieId, $0.createdAt) },
                                  uniquingKeysWith: { a, b in max(a, b) })
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
        do { customLists = try await supabase.myLists() }
        catch { SupabaseService.logSwallowed("RankingStore.refreshCustomLists", error) }
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
        // Building a list is high-effort curation — confirm it the way every
        // other save does, so it doesn't land silently.
        Haptics.success()
        ToastCenter.shared.show("Created “\(name)” 🎬")
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
            // Drop it locally FIRST — the refresh below is best-effort, and if
            // it fails the deleted list must not linger in the shared cache.
            customLists.removeAll { $0.id == id }
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

    /// Add a title to a custom list through the shared store, so an open list
    /// tab refreshes (via `listsRevision`) no matter where the add came from.
    /// Caches the movie first (the membership FK needs it). Returns false and
    /// toasts on failure.
    @discardableResult
    func addToList(_ listID: UUID, movie: Movie) async -> Bool {
        do {
            try await supabase.cacheMovie(movie)
            try await supabase.addToList(listID, movieID: movie.tmdbID)
            cache(movie)
            listsRevision += 1
            return true
        } catch {
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    /// Remove a title from a custom list through the store, so every surface
    /// (open list tab, counts) refreshes via `listsRevision` — the mirror of
    /// addToList. Returns false and toasts on failure so the caller can revert.
    @discardableResult
    func removeFromList(_ listID: UUID, movieID: Int) async -> Bool {
        do {
            try await supabase.removeFromList(listID, movieID: movieID)
            listsRevision += 1
            return true
        } catch {
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    // MARK: - Reading

    var watchedCount: Int { lists.values.reduce(0) { $0 + $1.count } }
    var watchlistCount: Int { watchlist.count }

    func movie(_ id: Int) -> Movie? { movies[id] }
    func isWatched(_ movieID: Int) -> Bool { lists.values.contains { $0.contains(movieID) } }
    func isOnWatchlist(_ movieID: Int) -> Bool { watchlistIDs.contains(movieID) }
    func scoredItem(for movieID: Int) -> ScoredItem<Int>? { scoredByID[movieID] }

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
        // Keep the pre-session list so a failed commit can restore it exactly
        // (a re-rank removes the entry below; without this, a dead connection
        // at commit time would leave the title missing or mis-ranked locally).
        // A repeat begin for the SAME title (Undo back to details → Okay)
        // must keep the ORIGINAL snapshot — the first beginReranking already
        // removed the entry, so re-snapshotting here would capture a list
        // that's missing it, and a failed commit would then erase the title
        // instead of restoring it.
        if preSessionList?.key != key || preSessionList?.movieID != movie.tmdbID {
            preSessionList = (key, movie.tmdbID, lists[key] ?? RankingList())
        }
        var kindList = lists[key] ?? RankingList()
        // Smart head-to-heads: seed the search where the PREDICTED score would
        // slot (so the first opponent is a title you'd score similarly, and it
        // varies per title instead of always the median), and bias opponents
        // toward SIMILAR titles (genre, shared director, and era). The opponent
        // set is the bucket minus the title itself, so a rerank's hints line up
        // with the post-remove bucket.
        let opponents = kindList.bucket(sentiment).filter { $0 != movie.tmdbID }
        let seed = seedPosition(for: movie, bucketSize: opponents.count, sentiment: sentiment)
        let sim = titleSimilarities(for: movie, against: opponents)
        let session = kindList.contains(movie.tmdbID)
            ? kindList.beginReranking(of: movie.tmdbID, sentiment: sentiment,
                                      seedPosition: seed, similarity: sim)
            : kindList.beginInsertion(of: movie.tmdbID, sentiment: sentiment,
                                      seedPosition: seed, similarity: sim)
        lists[key] = kindList
        listChanged()
        return session
    }

    /// Abandoning a session mid-flow: restore the exact pre-session list
    /// locally FIRST — a re-rank already removed the entry, and when offline
    /// the load() resync fails and keeps whatever is in memory, silently
    /// unranking the title for the rest of the session — then best-effort
    /// reconcile with the server.
    func abandonSession() async {
        if let snapshot = preSessionList {
            lists[snapshot.key] = snapshot.list
            preSessionList = nil
            listChanged()
        }
        await load()
    }

    /// Where the predicted score would slot in a bucket of `bucketSize` (the
    /// count of titles the bucket's scores beat it). Nil when we have no
    /// prediction or no opponents.
    private func seedPosition(for movie: Movie, bucketSize: Int, sentiment: Sentiment) -> Int? {
        guard bucketSize > 0, let predicted = predictedScores[movie.tmdbID] else { return nil }
        let scores = ScoreCalculator.scores(forBucketOf: bucketSize, sentiment: sentiment)
        return scores.filter { $0 > predicted }.count
    }

    /// How comparable each opponent is to the new title (0…1), aligned to
    /// `bucketIDs`. Blends genre overlap (most weight), a shared director, and
    /// release-year proximity, so the head-to-heads pit like against like. Nil
    /// when the new title carries no usable signal, or there are no opponents.
    private func titleSimilarities(for movie: Movie, against bucketIDs: [Int]) -> [Double]? {
        guard !bucketIDs.isEmpty else { return nil }
        let newGenres = Set(movie.genres)
        let newDirector = (movie.director?.isEmpty == false) ? movie.director : nil
        let newYear = movie.releaseYear
        // No signal at all → let it fall back to a plain binary search.
        guard !newGenres.isEmpty || newDirector != nil || newYear != nil else { return nil }
        return bucketIDs.map { id in
            guard let other = self.movie(id) else { return 0 }
            var score = 0.0
            // Genre overlap (Jaccard) — the strongest "same kind of movie" signal.
            let otherGenres = Set(other.genres)
            if !newGenres.isEmpty, !otherGenres.isEmpty {
                let union = newGenres.union(otherGenres).count
                score += 0.6 * (union == 0 ? 0
                    : Double(newGenres.intersection(otherGenres).count) / Double(union))
            }
            // Same director — two films by one director are highly comparable.
            if let nd = newDirector, let od = other.director, !od.isEmpty, nd == od {
                score += 0.25
            }
            // Same era — closer release years compare better (fades out by ~20y).
            if let ny = newYear, let oy = other.releaseYear {
                score += 0.15 * max(0, 1 - Double(abs(ny - oy)) / 20)
            }
            return score
        }
    }

    /// Commit locally and mirror to the rank_insert RPC. `onLocalScored` fires
    /// the moment the engine has computed the score — before the network write —
    /// so the log flow can show the result ticket immediately and let the write
    /// overlap the reveal's "calculating" beat. The returned value is non-nil
    /// only once the server confirms (nil = reverted + toasted).
    @discardableResult
    func commit(_ session: InsertionSession<Int>, watchDate: Date? = nil,
                stealth: Bool = false,
                onLocalScored: (ScoredItem<Int>) -> Void = { _ in }) async -> ScoredItem<Int>? {
        guard session.isComplete else { return nil }
        guard let bucketPosition = session.resolvedBucketPosition else {
            // Engine state should make this impossible; never crash on it.
            ToastCenter.shared.saveFailed()
            return nil
        }
        let key = kindKey(forMovie: session.newItemID)
        // Snapshot everything this commit mutates, so a failed write can
        // restore the pre-session state even when the connection is dead —
        // the load() resync below can't help then (it fails on the same dead
        // connection and keeps whatever is in memory). The kind list snapshot
        // comes from beginSession, from BEFORE a re-rank removed the entry.
        let previousKindList = (preSessionList?.key == key) ? preSessionList?.list : lists[key]
        let otherKey = key == "movie" ? "tv" : "movie"
        let previousOtherList = lists[otherKey]
        let previousWatchlistItem = watchlist.first { $0.movieID == session.newItemID }
        var kindList = lists[key] ?? RankingList()
        let scored = kindList.commit(session)
        lists[key] = kindList
        // Re-logging a title with its media kind flipped (movie ↔ TV) files it
        // under the new kind; drop the old entry or it shows up in BOTH lists.
        if var otherList = lists[otherKey], otherList.remove(session.newItemID) {
            lists[otherKey] = otherList
        }
        listChanged()
        watchlist.removeAll { $0.movieID == session.newItemID }
        // Score is known now (pure engine math) — hand it back so the UI can
        // reveal the ticket while the round-trip below runs.
        onLocalScored(scored)

        // One persist attempt, BOUNDED BY A TIMEOUT. A flaky connection that
        // hangs (rather than failing fast) would otherwise leave the write
        // pending ~60s — stranding the user on the "calculating" reveal screen.
        // Capping it means a bad connection resolves in seconds: we retry once,
        // then revert + toast so the screen always moves on.
        func attempt() async -> Bool {
            let work = Task { () -> Bool in
                do {
                    if let movie = movies[session.newItemID] {
                        try await supabase.cacheMovie(movie)   // rank_insert FKs onto movies
                    }
                    _ = try await supabase.rankInsert(
                        movieID: session.newItemID, bucket: session.sentiment,
                        position: bucketPosition, watchDate: watchDate, stealth: stealth)
                    return true
                } catch {
                    return false
                }
            }
            let timeout = Task { try? await Task.sleep(for: .seconds(12)); work.cancel() }
            let ok = await work.value
            timeout.cancel()
            return ok
        }

        var saved = await attempt()
        if !saved {
            try? await Task.sleep(for: .seconds(1))   // a transient blip shouldn't drop a rank
            saved = await attempt()
        }
        if !saved {
            // Both attempts failed/timed out: restore the exact pre-commit state
            // (a first-time rank vanishes; a failed RE-rank returns to its prior
            // position; the watchlist entry comes back), then best-effort resync
            // from the server in case the connection recovered. nil tells the
            // log flow to show an error instead of the result ticket.
            lists[key] = previousKindList ?? RankingList()
            lists[otherKey] = previousOtherList ?? RankingList()
            if let item = previousWatchlistItem,
               !watchlist.contains(where: { $0.movieID == item.movieID }) {
                watchlist.append(item)
            }
            preSessionList = nil
            listChanged()
            await load()
            ToastCenter.shared.saveFailed()
            return nil
        }
        preSessionList = nil
        // Freshly ranked → it sorts as "just added" until the next load reads
        // the real server timestamp.
        rankedAt[session.newItemID] = Date()
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
            // exists — pull it too (best-effort, but leave a trace).
            do { try await supabase.hideRankEvent(movieID: movieID) }
            catch { SupabaseService.logSwallowed("hideRankEvent", error) }
            return true
        } catch {
            ToastCenter.shared.saveFailed()
            return false
        }
    }

    // MARK: - Watchlist

    /// Titles with an in-flight watchlist toggle, so a rapid double-tap can't
    /// fire add+remove racing the network and desync the saved state.
    @ObservationIgnored private var togglingWatchlist: Set<Int> = []

    func toggleWatchlist(movie: Movie) async {
        guard !togglingWatchlist.contains(movie.tmdbID) else { return }
        togglingWatchlist.insert(movie.tmdbID)
        defer { togglingWatchlist.remove(movie.tmdbID) }
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

    /// "Why I saved this" — local state plus the server row. Reverts the
    /// optimistic edit if the write fails so the UI never shows a phantom note.
    func setWatchlistNote(movieID: Int, note: String) async {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let index = watchlist.firstIndex(where: { $0.movieID == movieID }) else {
            await supabase.setWatchlistNote(movieID: movieID, note: trimmed)
            return
        }
        let previous = watchlist[index].note
        watchlist[index].note = trimmed.isEmpty ? nil : trimmed
        let saved = await supabase.setWatchlistNote(movieID: movieID, note: trimmed)
        // Re-find by id after the await — the list may have changed during the
        // round-trip, so the captured index could be stale or out of bounds.
        if !saved, let i = watchlist.firstIndex(where: { $0.movieID == movieID }) {
            watchlist[i].note = previous
        }
    }

    /// "Watch by" goal — local state plus the server row (nil clears it).
    /// Reverts the optimistic edit if the write fails.
    func setWatchBy(movieID: Int, date: Date?) async {
        let iso = date.map { RankingStore.watchByFormatter.string(from: $0) }
        guard let index = watchlist.firstIndex(where: { $0.movieID == movieID }) else {
            await supabase.setWatchBy(movieID: movieID, date: iso)
            return
        }
        let previous = watchlist[index].watchBy
        watchlist[index].watchBy = iso
        let saved = await supabase.setWatchBy(movieID: movieID, date: iso)
        // Re-find by id after the await (the captured index may be stale).
        if !saved, let i = watchlist.firstIndex(where: { $0.movieID == movieID }) {
            watchlist[i].watchBy = previous
        }
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
