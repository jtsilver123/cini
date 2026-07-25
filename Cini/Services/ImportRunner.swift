import SwiftUI
import UserNotifications

/// One finished import, as the history screen shows it: when, what landed,
/// and — importantly — what DIDN'T match, by name, so "did my whole library
/// make it?" has a real answer.
struct ImportHistoryEntry: Codable, Identifiable {
    let id: UUID
    let date: Date
    let toRank: Int
    let saved: Int
    let reviews: Int
    let lists: Int
    let unmatched: [String]
    let detailsFailed: Bool
    /// Shows routed to Currently Watching (nil on entries logged before
    /// this field existed).
    let watching: Int?
}

/// Local, per-device log of past imports (capped at the last 20).
enum ImportHistory {
    private static let key = "import.history"

    static func all() -> [ImportHistoryEntry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let entries = try? JSONDecoder().decode([ImportHistoryEntry].self, from: data)
        else { return [] }
        return entries
    }

    static func add(_ entry: ImportHistoryEntry) {
        let entries = Array(([entry] + all()).prefix(20))
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Sign-out: the next account must not see the previous one's imports.
    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// The import pipeline, running app-wide: download → parse → TMDB match →
/// queue/watchlist/reviews/lists. It used to live inside the import screen,
/// which meant closing that screen (or just using the app) killed a
/// half-done import. Now the screen only STARTS imports and renders this
/// runner's state — the user is free to browse while it works, a status
/// chip above the tab bar tracks it anywhere, and a local notification
/// lands when it finishes with the app in the background.
@MainActor
@Observable
final class ImportRunner {
    static let shared = ImportRunner()

    enum RunState: Equatable {
        case idle, running, done
        case failed(String)
    }

    private(set) var state: RunState = .idle
    private(set) var progressText = ""
    private(set) var progressFraction: Double = 0
    private(set) var etaText: String?
    private(set) var result: LetterboxdImporter.Result?
    private(set) var pastedToWatchlist = false
    private(set) var detailsImportFailed = false
    private(set) var watchlistImportFailed = false

    private var task: Task<Void, Never>?
    private var store: RankingStore?
    private var matchingStarted: Date?
    /// Who started this run. Every server write re-checks it — a sign-out
    /// mid-import must never dump this library into the next account.
    private var ownerID: UUID?

    /// True while the account that started the run is still the signed-in one.
    private var ownerStillSignedIn: Bool {
        ownerID != nil && SupabaseService.shared.currentUserID == ownerID
    }

    /// Stop-the-run check used at every write gate: cancelled, or the account
    /// changed under us.
    private var aborted: Bool {
        Task.isCancelled || !ownerStillSignedIn
    }

    // MARK: - Entry points

    /// Import export file(s) already on device (file picker / desktop
    /// transfer download).
    func startFiles(_ urls: [URL], store: RankingStore) {
        begin(store: store) { try await self.runImport(from: urls) }
    }

    /// Import a pasted text list.
    func startText(_ text: String, toWatchlist: Bool, store: RankingStore) {
        begin(store: store) { try await self.runPasted(text, toWatchlist: toWatchlist) }
    }

    /// A desktop-transfer upload is ready in Storage — download and import.
    func startFromStorage(paths: [String], store: RankingStore) {
        guard state != .running else { return }
        ImportTransfer.clear()
        Haptics.tap()
        ToastCenter.shared.show(paths.count > 1
                                ? "Your exports landed — importing now 🎬"
                                : "Your export landed — importing now 🎬")
        begin(store: store) {
            self.progressText = "Downloading your export…"
            // Cap at two — the page only ever sends Letterboxd + Netflix.
            let capped = Array(paths.prefix(2))
            var urls: [URL] = []
            for (index, path) in capped.enumerated() {
                self.progressText = capped.count > 1
                    ? "Downloading file \(index + 1) of \(capped.count)…"
                    : "Downloading your export…"
                self.progressFraction = Double(index) / Double(capped.count)
                let data = try await SupabaseService.shared.downloadImport(path: path)
                let filename = (path as NSString).lastPathComponent
                let tempURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(filename)
                try data.write(to: tempURL)
                urls.append(tempURL)
            }
            try await self.runImport(from: urls)
        }
    }

    /// Stop the current import (Stop button). State returns to idle.
    func cancel() {
        task?.cancel()
        task = nil
        state = .idle
        result = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The user has seen the summary (or dismissed the chip) — back to idle.
    func acknowledge() {
        guard state != .running else { return }
        state = .idle
        result = nil
    }

    // MARK: - Lifecycle

    private func begin(store: RankingStore, _ work: @escaping () async throws -> Void) {
        guard state != .running else { return }
        task?.cancel()
        self.store = store
        ownerID = SupabaseService.shared.currentUserID
        result = nil
        detailsImportFailed = false
        watchlistImportFailed = false
        pastedToWatchlist = false
        progressText = "Reading export…"
        progressFraction = 0
        etaText = nil
        matchingStarted = nil
        state = .running
        // A 1,500-film library works for a couple of minutes — the screen
        // must not auto-lock and suspend it mid-run.
        UIApplication.shared.isIdleTimerDisabled = true
        // Switching apps mid-import suspends the process within seconds
        // (isIdleTimerDisabled does nothing once backgrounded) — a background
        // task assertion buys the ~30s grace window that finishes small
        // imports and lets big ones checkpoint instead of freezing mid-phase.
        // Same pattern as RankingStore.commit's rank-write protection.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "letterboxd-import")
        task = Task {
            defer {
                UIApplication.shared.isIdleTimerDisabled = false
                if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
            }
            do {
                try await work()
            } catch is CancellationError {
                // User tapped Stop — quiet return to idle happened in cancel().
            } catch {
                // Stop during the download phase surfaces as URLError.cancelled
                // (not CancellationError) — that's still a quiet cancel, not
                // "something went wrong reading that file".
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                let message = (error as? LocalizedError)?.errorDescription
                    ?? "Something went wrong reading that file."
                Haptics.error()
                state = .failed(message)
            }
        }
    }

    private func finish(_ outcome: LetterboxdImporter.Result) {
        result = outcome
        state = .done
        Haptics.success()
        let line = successLine(for: outcome)
        ToastCenter.shared.show(line)
        // Log it — the history screen answers "what landed, what didn't?"
        // long after this toast is gone.
        ImportHistory.add(ImportHistoryEntry(
            id: UUID(),
            date: Date(),
            toRank: pastedToWatchlist ? 0 : outcome.watched.count,
            saved: pastedToWatchlist ? outcome.watched.count : outcome.watchlist.count,
            reviews: outcome.watched.filter { $0.imported.review != nil }.count,
            lists: outcome.importedLists.count,
            unmatched: outcome.unmatched.map { title in
                title.year.map { "\(title.title) (\($0))" } ?? title.title
            },
            detailsFailed: detailsImportFailed,
            watching: outcome.stillWatching.count))
        // App in the background? Land a notification so "import done" reaches
        // the user without them babysitting the screen.
        if UIApplication.shared.applicationState != .active {
            let content = UNMutableNotificationContent()
            content.title = "Import complete 🎬"
            content.body = line
            content.userInfo = ["kind": "import_done"]
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            Task { try? await UNUserNotificationCenter.current().add(request) }
        }
    }

    // MARK: - Pipeline (moved from the import screen)

    private func runPasted(_ text: String, toWatchlist: Bool) async throws {
        guard let store else { return }
        progressText = "Reading your list…"
        let outcome = try await LetterboxdImporter.runText(text) { [weak self] progress in
            self?.applyProgress(progress, prefix: "")
        }
        etaText = nil
        pastedToWatchlist = toWatchlist
        if toWatchlist {
            let pending = outcome.watched.filter {
                !store.isOnWatchlist($0.movie.tmdbID) && !store.isWatched($0.movie.tmdbID)
            }
            if !pending.isEmpty, !aborted {
                await saveWatchlistBulk(pending)
            }
        } else if !aborted {
            ImportQueue.shared.seed(with: outcome.watched, store: store)
        }
        guard !aborted else { return }
        finish(outcome)
    }

    private func runImport(from urls: [URL]) async throws {
        guard let store else { return }
        // Run each export through the parser/matcher, then fold them into a
        // single outcome so the rest of the import (queue seed, reviews,
        // watchlist, lists) runs once over the combined set.
        var results: [LetterboxdImporter.Result] = []
        for (index, url) in urls.enumerated() {
            let prefix = urls.count > 1 ? "File \(index + 1) of \(urls.count): " : ""
            // ETA rate resets per file — Netflix and Letterboxd files match
            // at different speeds.
            matchingStarted = nil
            etaText = nil
            let r = try await LetterboxdImporter.run(fileURL: url) { [weak self] progress in
                self?.applyProgress(progress, prefix: prefix)
            }
            results.append(r)
        }
        etaText = nil
        var outcome = Self.mergeImportResults(results)
        // Only bring in net-new titles: skip anything already ranked
        // (watched), and skip watchlist entries already saved or ranked, so
        // re-importing never duplicates what's already in your library.
        outcome.watched = outcome.watched.filter { !store.isWatched($0.movie.tmdbID) }
        outcome.watchlist = outcome.watchlist.filter {
            !store.isWatched($0.movie.tmdbID) && !store.isOnWatchlist($0.movie.tmdbID)
        }

        // Shows with RECENT Netflix activity are mid-flight — mark them as
        // Currently Watching (with the season) instead of pretending they're
        // finished and asking the user to rank them.
        let inProgress = outcome.watched.filter {
            $0.movie.mediaKind == "tv" && $0.imported.stillWatching
        }
        if !inProgress.isEmpty {
            let inProgressIDs = Set(inProgress.map(\.movie.tmdbID))
            outcome.watched.removeAll { inProgressIDs.contains($0.movie.tmdbID) }
            outcome.stillWatching = inProgress
            progressText = "Marking shows you're still watching…"
            for match in inProgress {
                if aborted { break }
                store.cache(match.movie)
                try? await SupabaseService.shared.cacheMovie(match.movie)
                try? await SupabaseService.shared.setShowProgress(
                    showID: match.movie.tmdbID,
                    season: match.imported.lastSeason,
                    episode: nil)
            }
        }

        // Seed the persistent ranking queue (favorites first).
        ImportQueue.shared.seed(with: outcome.watched, store: store)

        // Reviews → Your Details notes; diary dates (every rewatch) →
        // the Diary. All server-side in bulk, so huge histories land
        // fast — and a failure is SAID, never shrugged off.
        let detailItems = outcome.watched
            .filter { $0.imported.review != nil || !$0.imported.watchDates.isEmpty }
            .map { match in
                SupabaseService.ImportDetailItem(
                    tmdb_id: match.movie.tmdbID,
                    media_kind: match.movie.mediaKind,
                    title: match.movie.title,
                    release_year: match.movie.releaseYear,
                    poster_path: match.movie.posterPath,
                    review: match.imported.review,
                    watched_on: match.imported.watchedOn,
                    watched_dates: match.imported.watchDates.sorted())
            }
        if !detailItems.isEmpty {
            // Chunked: a 1,500-film library in ONE payload risks a
            // request-size/statement timeout — 400 rows at a time lands
            // reliably and keeps the bar honest.
            let chunks = stride(from: 0, to: detailItems.count, by: 400).map {
                Array(detailItems[$0..<min($0 + 400, detailItems.count)])
            }
            for (index, chunk) in chunks.enumerated() {
                if aborted { break }
                progressText = chunks.count > 1
                    ? "Saving your reviews and watch dates… (\(index + 1) of \(chunks.count))"
                    : "Saving your reviews and watch dates…"
                progressFraction = Double(index + 1) / Double(chunks.count)
                do {
                    try await SupabaseService.shared.importMovieDetails(chunk)
                } catch {
                    // One quiet retry — the RPC is idempotent.
                    do {
                        try await SupabaseService.shared.importMovieDetails(chunk)
                    } catch {
                        SupabaseService.logSwallowed("import_movie_details", error)
                        detailsImportFailed = true
                    }
                }
            }
        }

        // Letterboxd watchlist → Cini watchlist, in bulk: one quiet RPC per
        // 400 titles instead of two round trips per title (a 300-film
        // watchlist used to take minutes here — and spray 'watchlisted'
        // feed events at followers while it did).
        let pendingSaves = outcome.watchlist.filter {
            !store.isOnWatchlist($0.movie.tmdbID) && !store.isWatched($0.movie.tmdbID)
        }
        if !pendingSaves.isEmpty, !aborted {
            await saveWatchlistBulk(pendingSaves)
        }

        // Letterboxd custom lists → Cini lists (same name reused). A failed
        // read of existing lists must NOT look like "you have none" — that
        // would re-create every list as new on a retry. Skip the phase then.
        if !aborted, !outcome.importedLists.isEmpty,
           let existing = try? await SupabaseService.shared.myLists() {
            progressText = "Rebuilding your lists…"
            for list in outcome.importedLists {
                if aborted { break }
                var target = existing.first {
                    $0.name.localizedCaseInsensitiveCompare(list.name) == .orderedSame
                }
                if target == nil {
                    target = try? await SupabaseService.shared.createList(name: list.name)
                }
                guard let target else { continue }
                for match in list.matches {
                    if aborted { break }
                    store.cache(match.movie)
                    try? await SupabaseService.shared.cacheMovie(match.movie)
                    try? await SupabaseService.shared.addToList(target.id, movieID: match.movie.tmdbID)
                }
            }
            await store.refreshCustomLists()
        }

        guard !aborted else { return }
        finish(outcome)
    }

    private func applyProgress(_ progress: LetterboxdImporter.Progress, prefix: String) {
        switch progress {
        case .reading:
            progressText = "\(prefix)Reading export…"
        case .matching(let done, let total):
            progressText = "\(prefix)Matching \(done) of \(total)"
            progressFraction = Double(done) / Double(max(total, 1))
            updateETA(done: done, total: total)
        }
    }

    /// "About 2 minutes left" from the observed matching rate — only once
    /// enough titles are done for the rate to mean something.
    private func updateETA(done: Int, total: Int) {
        if matchingStarted == nil { matchingStarted = Date() }
        guard let started = matchingStarted, done >= 20, total > done else {
            if done >= total { etaText = nil }
            return
        }
        let rate = Double(done) / max(Date().timeIntervalSince(started), 0.1)
        let secondsLeft = Double(total - done) / max(rate, 0.1)
        if secondsLeft < 50 {
            etaText = "Under a minute left"
        } else {
            let minutes = max(1, Int((secondsLeft / 60).rounded()))
            etaText = "About \(minutes) minute\(minutes == 1 ? "" : "s") left"
        }
    }

    /// Bulk-save matched titles to the watchlist: one quiet RPC per 400
    /// titles (retried once — it's idempotent), then reload the shared store
    /// so the app reflects rows the RPC wrote behind its back.
    private func saveWatchlistBulk(_ matches: [LetterboxdImporter.MatchedTitle]) async {
        guard let store else { return }
        progressText = "Saving your watchlist… \(matches.count) title\(matches.count == 1 ? "" : "s")"
        let items = matches.map { match in
            SupabaseService.ImportDetailItem(
                tmdb_id: match.movie.tmdbID,
                media_kind: match.movie.mediaKind,
                title: match.movie.title,
                release_year: match.movie.releaseYear,
                poster_path: match.movie.posterPath,
                review: nil,
                watched_on: nil,
                watched_dates: [])
        }
        let chunks = stride(from: 0, to: items.count, by: 400).map {
            Array(items[$0..<min($0 + 400, items.count)])
        }
        for (index, chunk) in chunks.enumerated() {
            if aborted { return }
            progressFraction = Double(index + 1) / Double(chunks.count)
            do {
                try await SupabaseService.shared.importWatchlist(chunk)
            } catch {
                do {
                    try await SupabaseService.shared.importWatchlist(chunk)
                } catch {
                    SupabaseService.logSwallowed("import_watchlist", error)
                    watchlistImportFailed = true
                    ToastCenter.shared.saveFailed()
                    break
                }
            }
        }
        matches.forEach { store.cache($0.movie) }
        // Reconcile the single shared cache with what the server now holds.
        await store.load()
    }

    /// "Imported 389 to rank · 57 saved · 2 lists" — the one-line receipt.
    func successLine(for outcome: LetterboxdImporter.Result) -> String {
        var parts: [String] = []
        if pastedToWatchlist {
            parts.append(watchlistImportFailed
                         ? "some titles didn't come over — run the import again"
                         : "\(outcome.watched.count) saved to Want to Watch")
        } else {
            if !outcome.watched.isEmpty { parts.append("\(outcome.watched.count) to rank") }
            if !outcome.watchlist.isEmpty {
                parts.append(watchlistImportFailed
                             ? "some of \(outcome.watchlist.count) saves didn't sync — run the import again"
                             : "\(outcome.watchlist.count) saved")
            }
        }
        if !outcome.stillWatching.isEmpty {
            parts.append("\(outcome.stillWatching.count) still watching")
        }
        let reviews = outcome.watched.filter { $0.imported.review != nil }.count
        if reviews > 0 && !detailsImportFailed {
            parts.append("\(reviews) review\(reviews == 1 ? "" : "s")")
        }
        if !outcome.importedLists.isEmpty {
            parts.append("\(outcome.importedLists.count) list\(outcome.importedLists.count == 1 ? "" : "s")")
        }
        if !outcome.errored.isEmpty {
            parts.append("\(outcome.errored.count) couldn't be checked (connection trouble) — run the import again")
        }
        return parts.isEmpty ? "Import complete" : "Imported: " + parts.joined(separator: " · ")
    }

    /// Fold several parsed exports (e.g. Letterboxd + Netflix) into one result,
    /// de-duping by TMDB id so a title in both isn't queued or counted twice.
    /// Watched wins over watchlist; richer metadata (a review, more watch dates,
    /// a like) is kept when the same title appears in more than one file.
    static func mergeImportResults(_ results: [LetterboxdImporter.Result]) -> LetterboxdImporter.Result {
        guard results.count > 1 else { return results.first ?? LetterboxdImporter.Result() }

        var watchedByID: [Int: LetterboxdImporter.MatchedTitle] = [:]
        var watchedOrder: [Int] = []
        for result in results {
            for match in result.watched {
                let id = match.movie.tmdbID
                if let existing = watchedByID[id] {
                    watchedByID[id] = combineMatches(existing, match)
                } else {
                    watchedByID[id] = match
                    watchedOrder.append(id)
                }
            }
        }

        var watchlistByID: [Int: LetterboxdImporter.MatchedTitle] = [:]
        var watchlistOrder: [Int] = []
        for result in results {
            for match in result.watchlist where watchedByID[match.movie.tmdbID] == nil {
                let id = match.movie.tmdbID
                if watchlistByID[id] == nil {
                    watchlistByID[id] = match
                    watchlistOrder.append(id)
                }
            }
        }

        var merged = LetterboxdImporter.Result()
        merged.watched = watchedOrder.compactMap { watchedByID[$0] }
        merged.watchlist = watchlistOrder.compactMap { watchlistByID[$0] }
        merged.importedLists = results.flatMap { $0.importedLists }
        merged.unmatched = results.flatMap { $0.unmatched }
        merged.errored = results.flatMap { $0.errored }
        merged.totalParsed = results.reduce(0) { $0 + $1.totalParsed }
        return merged
    }

    /// Merge the imported metadata for a title that showed up in two files.
    private static func combineMatches(_ a: LetterboxdImporter.MatchedTitle,
                                       _ b: LetterboxdImporter.MatchedTitle) -> LetterboxdImporter.MatchedTitle {
        var imported = a.imported
        imported.review = imported.review ?? b.imported.review
        imported.watchedOn = imported.watchedOn ?? b.imported.watchedOn
        imported.rating = imported.rating ?? b.imported.rating
        imported.liked = imported.liked || b.imported.liked
        imported.watchDates.formUnion(b.imported.watchDates)
        // A mid-binge show in either file stays "still watching" — dropping
        // the flag here would queue a half-watched show to rank.
        imported.stillWatching = imported.stillWatching || b.imported.stillWatching
        if let other = b.imported.lastSeason, other > (imported.lastSeason ?? 0) {
            imported.lastSeason = other
        }
        return LetterboxdImporter.MatchedTitle(imported: imported, movie: a.movie)
    }
}
