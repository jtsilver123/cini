import Foundation

/// Showtimes near a zipcode — Cini's analog of Beli's "Reserve now".
/// Backed by Gracenote OnConnect (data.tmsapi.com): one call returns every
/// movie showing near the zip, we pick ours by fuzzy title + year match,
/// then group its showtimes by theatre. Without a key the UI degrades to
/// the "coming soon" state.
protocol ShowtimesProviding {
    func showtimes(for movie: Movie, zipcode: String, date: Date) async throws -> [TheaterShowtimes]
}

struct TheaterShowtimes: Identifiable, Hashable {
    let id: String
    let theaterName: String
    /// Theatre-level perks aggregated from its showings ("Recliners",
    /// "Reserved Seating") — the closest thing Gracenote has to seat info.
    let amenities: [String]
    let showtimes: [Showtime]
}

struct Showtime: Identifiable, Hashable {
    let id: String
    let startTime: Date
    let format: String?      // "IMAX", "4DX", "Dolby", …
    /// Bargain/matinee pricing flagged by the theatre.
    let isBargain: Bool
    let bookingURL: URL?
}

enum ShowtimesError: Error {
    case notConfigured
    case zipcodeNotFound
}

final class ShowtimesService: ShowtimesProviding {
    static let shared = ShowtimesService()

    /// Strip Gracenote's screening-variant dressing from a listing title so
    /// it compares against the film's canonical name: "Dune: Part Two: The
    /// IMAX 2D Experience" → "Dune: Part Two", "Oppenheimer 70mm" →
    /// "Oppenheimer", "Casablanca (80th Anniversary)" → "Casablanca".
    static func canonicalTitle(_ raw: String) -> String {
        var title = raw
        let patterns = [
            #"[:\-–—]?\s*((the|an?)\s+)?imax(\s+(2d|3d|70mm|laser))?(\s+experience)?\s*$"#,
            #"[:\-–—]?\s*(an?\s+)?(imax|4dx|screenx|rpx|dolby(\s+(cinema|atmos))?)\s*(experience)?\s*$"#,
            #"[:\-–—]?\s*(in\s+)?(3d|70\s?mm|35\s?mm)\s*$"#,
            #"[:\-–—]?\s*\(?\d+(th|st|nd|rd)\s+anniversary\)?\s*$"#,
            #"[:\-–—]?\s*\(?(re-?release|remastered|restoration|extended\s+(edition|version|cut)|director'?s\s+cut)\)?\s*$"#,
            #"\s*\(\d{4}\)\s*$"#,
        ]
        var changed = true
        while changed {
            changed = false
            for pattern in patterns {
                let stripped = title.replacingOccurrences(
                    of: pattern, with: "", options: [.regularExpression, .caseInsensitive])
                if stripped != title, !stripped.trimmingCharacters(in: .whitespaces).isEmpty {
                    title = stripped
                    changed = true
                }
            }
        }
        // A stripped variant can leave its joiner behind ("Aliens:") — drop it.
        while let last = title.last, last == ":" || last == "-" || last == "–"
                || last == "—" || last == " " {
            title.removeLast()
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func showtimes(for movie: Movie, zipcode: String, date: Date) async throws -> [TheaterShowtimes] {
        guard let apiKey = AppConfig.showtimesAPIKey else {
            throw ShowtimesError.notConfigured
        }
        // TV shows (negative ids) have no theatrical showtimes — a fuzzy
        // match against whatever's playing would invent some.
        guard movie.tmdbID > 0 else { return [] }

        // The user's LOCAL calendar day — a UTC day here would query tomorrow's
        // showtimes for any US user browsing in the evening.
        let day = DateFormatter.localDay.string(from: date)
        var components = URLComponents(string: "https://data.tmsapi.com/v1.1/movies/showings") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "startDate", value: day),
            URLQueryItem(name: "zip", value: zipcode),
            URLQueryItem(name: "radius", value: "15"),
            URLQueryItem(name: "units", value: "mi"),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 400 { throw ShowtimesError.zipcodeNotFound }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        let listings = try JSONDecoder().decode([GNMovie].self, from: data)

        // Find our film among everything playing nearby. Gracenote lists
        // premium screenings as SEPARATE title variants ("…: The IMAX 2D
        // Experience", "… 70mm", "… (25th Anniversary)"), so score against
        // the CANONICAL title and merge every matching variant — otherwise
        // the IMAX showings simply vanish from the sheet.
        let scored = listings.map { listing -> (GNMovie, Double) in
            var score = Fuzzy.similarity(query: movie.title,
                                         candidate: Self.canonicalTitle(listing.title))
            if let want = movie.releaseYear, let got = listing.releaseYear {
                score += want == got ? 0.15 : (abs(want - got) > 1 ? -0.25 : 0)
            }
            return (listing, score)
        }
        guard let bestScore = scored.map(\.1).max(), bestScore > 0.6 else { return [] }
        // The winner plus its variants: same canonical title, or scored
        // within a hair of the best (year bonus can differ per listing).
        let bestCanonical = scored.max { $0.1 < $1.1 }
            .map { Self.canonicalTitle($0.0.title).lowercased() } ?? ""
        let matches = scored.filter { listing, score in
            score > 0.6 && (score >= bestScore - 0.05
                || Self.canonicalTitle(listing.title).lowercased() == bestCanonical)
        }.map(\.0)

        // Group all matched showtimes by theatre, collecting seat-comfort perks.
        var byTheatre: [String: (name: String, perks: Set<String>, times: [Showtime])] = [:]
        var seenIDs: Set<String> = []
        for listing in matches {
            // A variant listing often carries its format in the TITLE
            // ("…: The IMAX 2D Experience") while its showings' quals stay
            // silent — fall back to the title so the screen filter sees it.
            let titleFormat = GNMovie.Showing.premiumFormat(in: listing.title)
            for showing in listing.showtimes ?? [] {
                guard let theatre = showing.theatre,
                      let start = DateFormatter.gracenoteDateTime.date(from: showing.dateTime ?? "") else { continue }
                let key = theatre.id ?? theatre.name ?? "?"
                let format = showing.format ?? titleFormat
                // Same theatre + time can exist per FORMAT (IMAX room and a
                // standard room both at 7:30) — distinct; true dupes are dropped.
                let id = "\(key)-\(showing.dateTime ?? "")-\(format ?? "std")"
                guard seenIDs.insert(id).inserted else { continue }
                let entry = Showtime(
                    id: id,
                    startTime: start,
                    format: format,
                    isBargain: showing.barg ?? false,
                    bookingURL: showing.secureTicketURL
                )
                var bucket = byTheatre[key] ?? (theatre.name ?? "Theater", [], [])
                bucket.name = theatre.name ?? bucket.name
                bucket.perks.formUnion(showing.perks)
                bucket.times.append(entry)
                byTheatre[key] = bucket
            }
        }

        return byTheatre
            .map { id, value in
                TheaterShowtimes(
                    id: id,
                    theaterName: value.name,
                    amenities: value.perks.sorted(),
                    showtimes: value.times.sorted { $0.startTime < $1.startTime }
                )
            }
            .sorted { $0.theaterName < $1.theaterName }
    }
}

private extension DateFormatter {
    /// "2026-06-11T19:30" — local time, no zone or seconds.
    static let gracenoteDateTime: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return f
    }()
}

/// Test hook: the variant-title format fallback (GNMovie is file-private).
enum GNShowingFormatProbe {
    static func format(in text: String) -> String? {
        GNMovie.Showing.premiumFormat(in: text)
    }
}

// MARK: - Gracenote OnConnect DTOs

private struct GNMovie: Decodable {
    struct Showing: Decodable {
        struct Theatre: Decodable {
            let id: String?
            let name: String?
        }
        let theatre: Theatre?
        let dateTime: String?
        let ticketURI: String?
        let quals: String?
        let barg: Bool?

        private var qualList: [String] {
            (quals ?? "").split(separator: "|").map(String.init)
        }

        /// Premium screen format in free text ("IMAX", "4DX", "Dolby", …) —
        /// shared by the quals check and variant-title fallback.
        static func premiumFormat(in text: String) -> String? {
            let premiums = ["IMAX", "4DX", "RPX", "ScreenX", "70mm",
                            "Dolby", "ATMOS", "3D", "Laser"]
            for premium in premiums
            where text.localizedCaseInsensitiveContains(premium) {
                return premium == "ATMOS" ? "Dolby Atmos"
                     : premium == "Laser" ? "Laser" : premium
            }
            return nil
        }

        /// Premium screen format, if any, from the showing's qualifiers.
        var format: String? {
            for qual in qualList {
                if let format = Self.premiumFormat(in: qual) { return format }
            }
            return nil
        }

        /// Seat-comfort perks worth surfacing at the theatre level.
        var perks: Set<String> {
            var result: Set<String> = []
            for qual in qualList {
                if qual.localizedCaseInsensitiveContains("Recliner") { result.insert("Recliners") }
                if qual.localizedCaseInsensitiveContains("Reserved Seating") { result.insert("Reserved seating") }
            }
            return result
        }

        /// Gracenote hands out plain-http Fandango links; https is required
        /// for the Fandango app to claim them as universal links.
        var secureTicketURL: URL? {
            guard var raw = ticketURI else { return nil }
            if raw.hasPrefix("http://") {
                raw = "https://" + raw.dropFirst("http://".count)
            }
            return URL(string: raw)
        }
    }

    let title: String
    let releaseYear: Int?
    let showtimes: [Showing]?
}
