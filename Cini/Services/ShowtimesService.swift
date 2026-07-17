import Foundation

/// Showtimes near a zipcode — Cini's analog of Beli's "Reserve now".
/// Backed by Gracenote OnConnect (data.tmsapi.com): one call returns every
/// movie showing near the zip, we pick ours by fuzzy title + year match,
/// then group its showtimes by theatre. Without a key the UI degrades to
/// the "coming soon" state.
protocol ShowtimesProviding {
    func showtimes(for movie: Movie, zipcode: String, date: Date, radius: Int) async throws -> [TheaterShowtimes]
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
        // \b before each format token: without it "Climax" ends in "imax"
        // and canonicalizes to "Cl" — a real film that would never match.
        let patterns = [
            #"[:\-–—]?\s*((the|an?)\s+)?\bimax(\s+(2d|3d|70mm|laser))?(\s+experience)?\s*$"#,
            #"[:\-–—]?\s*(an?\s+)?\b(imax|4dx|screenx|rpx|dolby(\s+(cinema|atmos))?)\s*(experience)?\s*$"#,
            #"[:\-–—]?\s*(in\s+)?\b(3d|70\s?mm|35\s?mm)\s*$"#,
            #"[:\-–—]?\s*\(?\b\d+(th|st|nd|rd)\s+anniversary\)?\s*$"#,
            #"[:\-–—]?\s*\(?\b(re-?release|remastered|restoration|extended\s+(edition|version|cut)|director'?s\s+cut)\)?\s*$"#,
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

    func showtimes(for movie: Movie, zipcode: String, date: Date, radius: Int = 15) async throws -> [TheaterShowtimes] {
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
            URLQueryItem(name: "radius", value: String(max(1, min(radius, 100)))),
            URLQueryItem(name: "units", value: "mi"),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 400 { throw ShowtimesError.zipcodeNotFound }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

        let listings = try JSONDecoder().decode([GNMovie].self, from: data)
        let matches = Self.variantMatches(for: movie, in: listings)

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

    /// Which upcoming days does each of these films VERIFIABLY play near this
    /// zip? One Gracenote call covering the posted window (theaters publish
    /// about a week out) answers for all of them — the theater calendar marks
    /// future days from this, so it never claims a day the showtimes sheet
    /// can't back up. Returns tmdbID → set of local days with ≥1 showing.
    func playingDays(for movies: [Movie], zipcode: String, radius: Int = 15,
                     days: Int = 7) async throws -> [Int: Set<Date>] {
        guard let apiKey = AppConfig.showtimesAPIKey else {
            throw ShowtimesError.notConfigured
        }
        var components = URLComponents(string: "https://data.tmsapi.com/v1.1/movies/showings") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "startDate", value: DateFormatter.localDay.string(from: Date())),
            URLQueryItem(name: "numDays", value: String(max(1, min(days, 7)))),
            URLQueryItem(name: "zip", value: zipcode),
            URLQueryItem(name: "radius", value: String(max(1, min(radius, 100)))),
            URLQueryItem(name: "units", value: "mi"),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        guard let url = components.url else { throw URLError(.badURL) }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 400 { throw ShowtimesError.zipcodeNotFound }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let listings = try JSONDecoder().decode([GNMovie].self, from: data)

        let cal = Calendar.current
        var result: [Int: Set<Date>] = [:]
        for movie in movies where movie.tmdbID > 0 {
            for listing in Self.variantMatches(for: movie, in: listings) {
                for showing in listing.showtimes ?? [] {
                    guard let start = DateFormatter.gracenoteDateTime
                        .date(from: showing.dateTime ?? "") else { continue }
                    result[movie.tmdbID, default: []].insert(cal.startOfDay(for: start))
                }
            }
        }
        return result
    }

    /// Find our film among everything playing nearby. Gracenote lists
    /// premium screenings as SEPARATE title variants ("…: The IMAX 2D
    /// Experience", "… 70mm", "… (25th Anniversary)"), so score against
    /// the CANONICAL title and merge every matching variant — otherwise
    /// the IMAX showings simply vanish.
    private static func variantMatches(for movie: Movie, in listings: [GNMovie]) -> [GNMovie] {
        let scored = listings.map { listing -> (GNMovie, Double) in
            // Both years known and >1 apart = a DIFFERENT film, full stop.
            // A soft malus wasn't enough: "The Lion King" (1994) vs the 2019
            // remake share a canonical title, and 1.0 − 0.25 still cleared
            // the acceptance gate — the wrong film's showtimes shown with
            // total confidence.
            if let want = movie.releaseYear, let got = listing.releaseYear,
               abs(want - got) > 1 {
                return (listing, -1)
            }
            var score = Fuzzy.similarity(query: movie.title,
                                         candidate: canonicalTitle(listing.title))
            if movie.releaseYear != nil, movie.releaseYear == listing.releaseYear {
                score += 0.15
            }
            return (listing, score)
        }
        guard let bestScore = scored.map(\.1).max(), bestScore > 0.6 else { return [] }
        // The winner plus its variants: same canonical title, or scored
        // within a hair of the best (year bonus can differ per listing).
        // The canonical-equality path is YEAR-GATED: "Saw 3D" (2010)
        // canonicalizes to "Saw" (2004) but is a different film — a mismatched
        // year must not smuggle its showtimes in.
        let bestCanonical = scored.max { $0.1 < $1.1 }
            .map { canonicalTitle($0.0.title).lowercased() } ?? ""
        return scored.filter { listing, score in
            guard score > 0.6 else { return false }
            if score >= bestScore - 0.05 { return true }
            let yearCompatible = movie.releaseYear == nil || listing.releaseYear == nil
                || abs(movie.releaseYear! - listing.releaseYear!) <= 1
            return yearCompatible
                && canonicalTitle(listing.title).lowercased() == bestCanonical
        }.map(\.0)
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
        /// shared by the quals check and variant-title fallback. Scans the
        /// WHOLE text per premium so priority order wins ("3D|IMAX" reads
        /// IMAX, not 3D), and matches on word boundaries so "Climax" never
        /// reads as IMAX.
        static func premiumFormat(in text: String) -> String? {
            // ATMOS before Dolby: "Dolby Atmos" contains both tokens, and
            // checking Dolby first meant "Dolby Atmos" could never be
            // reported (so an Atmos viewing preference never matched).
            let premiums = ["IMAX", "4DX", "RPX", "ScreenX", "70mm",
                            "ATMOS", "Dolby", "3D", "Laser"]
            for premium in premiums
            where text.range(of: #"\b"# + premium + #"\b"#,
                             options: [.regularExpression, .caseInsensitive]) != nil {
                return premium == "ATMOS" ? "Dolby Atmos"
                     : premium == "Laser" ? "Laser" : premium
            }
            return nil
        }

        /// Premium screen format, if any, from the showing's qualifiers —
        /// checked across ALL of them at once so the priority order above
        /// decides, not whichever qualifier happens to come first.
        var format: String? {
            Self.premiumFormat(in: quals ?? "")
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
