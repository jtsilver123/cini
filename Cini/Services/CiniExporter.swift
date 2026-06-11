import Foundation

/// Exports the user's Cini data as CSVs in the column format Letterboxd's
/// importer accepts (letterboxd.com/about/importing-data): Title, Year,
/// tmdbID (exact matching on their side), Rating10, WatchedDate. Scores
/// snap to Letterboxd's half-point scale. Watchlist ships as a second
/// file for their watchlist importer.
enum CiniExporter {

    @MainActor
    static func makeLetterboxdFiles(store: RankingStore) async throws -> [URL] {
        guard let me = SupabaseService.shared.currentUserID else {
            throw URLError(.userAuthenticationRequired)
        }
        let rankings = try await SupabaseService.shared.rankings(userID: me)

        // Fill any metadata gaps from the server cache.
        var movies = store.movies
        let wanted = rankings.map(\.movieId) + store.watchlist.map(\.movieID)
        let missing = wanted.filter { movies[$0] == nil }
        if !missing.isEmpty,
           let rows = try? await SupabaseService.shared.movies(ids: missing) {
            for row in rows { movies[row.tmdbId] = row.asMovie }
        }

        var urls: [URL] = []

        // Watched: best first, scores mapped to Letterboxd's 0.5–10 scale.
        var watched = "Title,Year,tmdbID,Rating10,WatchedDate\n"
        for row in rankings.sorted(by: { $0.score > $1.score }) {
            guard let movie = movies[row.movieId] else { continue }
            let rating = max(0.5, (row.score * 2).rounded() / 2)
            let ratingText = rating.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rating))
                : String(format: "%.1f", rating)
            let date = row.watchDate
                ?? ISO8601DateFormatter.dateOnly.string(from: row.createdAt)
            watched += line([movie.title,
                             movie.releaseYear.map(String.init) ?? "",
                             String(movie.tmdbID),
                             ratingText,
                             date])
        }
        if !rankings.isEmpty {
            urls.append(try write(watched, name: "cini-watched.csv"))
        }

        // Watchlist: same columns minus rating/date.
        if !store.watchlist.isEmpty {
            var watchlist = "Title,Year,tmdbID\n"
            for item in store.watchlist {
                guard let movie = movies[item.movieID] else { continue }
                watchlist += line([movie.title,
                                   movie.releaseYear.map(String.init) ?? "",
                                   String(movie.tmdbID)])
            }
            urls.append(try write(watchlist, name: "cini-watchlist.csv"))
        }

        // Diary: every watch and rewatch with its date — round-trips with
        // the importer's diary handling.
        if let watches: [WatchRow] = try? await SupabaseService.shared.watches(of: me),
           !watches.isEmpty {
            var diary = "Title,Year,tmdbID,WatchedDate\n"
            let diaryMissing = watches.map(\.movieId).filter { movies[$0] == nil }
            if !diaryMissing.isEmpty,
               let rows = try? await SupabaseService.shared.movies(ids: diaryMissing) {
                for row in rows { movies[row.tmdbId] = row.asMovie }
            }
            for watch in watches.sorted(by: { $0.watchedOn < $1.watchedOn }) {
                guard let movie = movies[watch.movieId] else { continue }
                diary += line([movie.title,
                               movie.releaseYear.map(String.init) ?? "",
                               String(movie.tmdbID),
                               watch.watchedOn])
            }
            urls.append(try write(diary, name: "cini-diary.csv"))
        }

        // Reviews: your public notes, one row per film.
        if let notes = try? await SupabaseService.shared.myPublicNoteRows(),
           !notes.isEmpty {
            var reviews = "Title,Year,tmdbID,Review\n"
            let noteMissing = notes.map(\.movieId).filter { movies[$0] == nil }
            if !noteMissing.isEmpty,
               let rows = try? await SupabaseService.shared.movies(ids: noteMissing) {
                for row in rows { movies[row.tmdbId] = row.asMovie }
            }
            for note in notes {
                guard let movie = movies[note.movieId] else { continue }
                reviews += line([movie.title,
                                 movie.releaseYear.map(String.init) ?? "",
                                 String(movie.tmdbID),
                                 note.body])
            }
            urls.append(try write(reviews, name: "cini-reviews.csv"))
        }

        // Custom lists: one CSV each, Letterboxd's list shape.
        if let lists = try? await SupabaseService.shared.myLists() {
            for list in lists {
                guard let ids = try? await SupabaseService.shared.listMovieIDs(list.id),
                      !ids.isEmpty else { continue }
                let listMissing = ids.filter { movies[$0] == nil }
                if !listMissing.isEmpty,
                   let rows = try? await SupabaseService.shared.movies(ids: listMissing) {
                    for row in rows { movies[row.tmdbId] = row.asMovie }
                }
                var csv = "Position,Name,Year,tmdbID\n"
                for (index, id) in ids.enumerated() {
                    guard let movie = movies[id] else { continue }
                    csv += line([String(index + 1),
                                 movie.title,
                                 movie.releaseYear.map(String.init) ?? "",
                                 String(movie.tmdbID)])
                }
                let safeName = list.name.replacingOccurrences(
                    of: #"[^A-Za-z0-9 _-]"#, with: "", options: .regularExpression)
                urls.append(try write(csv, name: "cini-list-\(safeName).csv"))
            }
        }

        return urls
    }

    // MARK: CSV plumbing

    private static func line(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\n"
    }

    /// RFC 4180: quote fields containing commas, quotes, or newlines.
    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return field
    }

    private static func write(_ contents: String, name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
