import Foundation

/// Exports the user's Cini data as CSVs in the column format Letterboxd's
/// importer accepts (letterboxd.com/about/importing-data): Title, Year,
/// tmdbID (exact matching on their side), Rating10, WatchedDate. Scores
/// snap to Letterboxd's half-point scale. Watchlist ships as a second
/// file for their watchlist importer.
enum CiniExporter {

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
