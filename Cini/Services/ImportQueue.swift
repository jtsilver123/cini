import Foundation
import Observation

/// Persistent "Movies you may have seen" queue, seeded by Letterboxd/IMDb
/// import. Survives relaunches; shrinks as movies get ranked or dismissed.
@Observable
@MainActor
final class ImportQueue {
    static let shared = ImportQueue()

    struct Entry: Codable, Identifiable, Hashable {
        let movieID: Int
        let title: String
        let year: Int?
        /// Original 0.5–5★ rating from the import — ordering only,
        /// never shown as a Cini score.
        let importedRating: Double?

        var id: Int { movieID }
    }

    private(set) var entries: [Entry] = []
    /// How many imported titles have been ranked so far ("Ranked 52 of 93").
    private(set) var rankedFromImport = 0

    private let fileURL: URL

    init(filename: String = "import-queue.json") {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        fileURL = directory.appendingPathComponent(filename)
        load()
    }

    var isEmpty: Bool { entries.isEmpty }
    var totalImported: Int { entries.count + rankedFromImport }

    func seed(with matches: [LetterboxdImporter.MatchedTitle], store: RankingStore) {
        let existing = Set(entries.map(\.movieID))
        for match in matches where !existing.contains(match.movie.tmdbID) {
            store.cache(match.movie)
            guard !store.isWatched(match.movie.tmdbID) else { continue }
            entries.append(Entry(
                movieID: match.movie.tmdbID,
                title: match.movie.title,
                year: match.movie.releaseYear,
                importedRating: match.imported.rating
            ))
        }
        // Favorites first so ranking starts with the movies they loved.
        entries.sort { ($0.importedRating ?? -1) > ($1.importedRating ?? -1) }
        save()
    }

    /// Movie was ranked — counts toward import progress.
    func markRanked(_ movieID: Int) {
        guard entries.contains(where: { $0.movieID == movieID }) else { return }
        entries.removeAll { $0.movieID == movieID }
        rankedFromImport += 1
        save()
    }

    /// Movie was dismissed ("never saw it") — removed without progress.
    func dismiss(_ movieID: Int) {
        entries.removeAll { $0.movieID == movieID }
        save()
    }

    /// Wipe on sign-out — the next account on this device must never see
    /// the previous user's import queue.
    func clear() {
        entries = []
        rankedFromImport = 0
        save()
    }

    // MARK: Persistence

    private struct Snapshot: Codable {
        var entries: [Entry]
        var rankedFromImport: Int
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        entries = snapshot.entries
        rankedFromImport = snapshot.rankedFromImport
    }

    private func save() {
        let snapshot = Snapshot(entries: entries, rankedFromImport: rankedFromImport)
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
