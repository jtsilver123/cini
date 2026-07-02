import Foundation

/// Exports the user's Cini data as CSVs: a Watched file (Title, Year, Type,
/// tmdbID, Rating10, WatchedDate) and a Want-to-Watch file (Title, Year, Type,
/// tmdbID). Columns stay compatible with Letterboxd's importer
/// (letterboxd.com/about/importing-data), which ignores the extra Type column;
/// Type ("Movie" / "TV Show") lets the data round-trip into Cini, where shows
/// are first-class. Scores snap to Letterboxd's half-point scale.
enum CiniExporter {

    /// "Movie" or "TV Show" — Cini treats both equally, so the export labels it.
    private static func typeLabel(_ movie: Movie) -> String {
        movie.mediaKind == "tv" ? "TV Show" : "Movie"
    }

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
        var watched = "Title,Year,Type,tmdbID,Rating10,WatchedDate\n"
        for row in rankings.sorted(by: { $0.score > $1.score }) {
            guard let movie = movies[row.movieId] else { continue }
            let rating = max(0.5, (row.score * 2).rounded() / 2)
            let ratingText = rating.truncatingRemainder(dividingBy: 1) == 0
                ? String(Int(rating))
                : String(format: "%.1f", rating)
            let date = row.watchDate
                ?? DateFormatter.localDay.string(from: row.createdAt)
            watched += line([movie.title,
                             movie.releaseYear.map(String.init) ?? "",
                             typeLabel(movie),
                             String(movie.tmdbID),
                             ratingText,
                             date])
        }
        if !rankings.isEmpty {
            urls.append(try write(watched, name: "cini-watched.csv"))
        }

        // Want to Watch: same columns minus rating/date.
        if !store.watchlist.isEmpty {
            var watchlist = "Title,Year,Type,tmdbID\n"
            for item in store.watchlist {
                guard let movie = movies[item.movieID] else { continue }
                watchlist += line([movie.title,
                                   movie.releaseYear.map(String.init) ?? "",
                                   typeLabel(movie),
                                   String(movie.tmdbID)])
            }
            urls.append(try write(watchlist, name: "cini-watchlist.csv"))
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
    /// In Swift "\r\n" is ONE Character, so `contains("\n")` misses CRLF-only
    /// text (e.g. a note pasted from Windows) — check both line breaks.
    private static func escape(_ field: String) -> String {
        if field.contains(",") || field.contains("\"")
            || field.contains(where: \.isNewline) {
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
