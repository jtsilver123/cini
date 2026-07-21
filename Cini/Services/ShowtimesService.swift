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
            #"[:\-–—]?\s*(in\s+)?\b(3d|70\s?mm|35\s?mm)(\s+film)?\s*$"#,
            #"[:\-–—]?\s*\(?\b\d+(th|st|nd|rd)\s+anniversary\)?\s*$"#,
            #"[:\-–—]?\s*\(?\b(re-?release|remastered|restoration|extended\s+(edition|version|cut)|director'?s\s+cut|(the\s+)?final\s+cut)\)?\s*$"#,
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
        // Gracenote's NORMAL "no theaters in range" answer is 200 with a
        // ZERO-BYTE body (verified live across rural zips) — decoding it
        // throws and turned every search in a low-density area into
        // "Something went wrong". Empty body = empty slate.
        guard !data.isEmpty else { return [] }

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

        var theaters = byTheatre
            .map { id, value in
                TheaterShowtimes(
                    id: id,
                    theaterName: value.name,
                    amenities: value.perks.sorted(),
                    showtimes: value.times.sorted { $0.startTime < $1.startTime }
                )
            }
        // Indie venues publish direct — merge their showings for THIS movie
        // on THIS day, with real ticket links. Near-term days can exist in
        // both feeds: times within the same minute at the same venue dedupe.
        if let metro = Self.metro(forZip: zipcode) {
            let dayPrefix = day
            let supplemental = await supplementalRows(metro: metro).filter {
                $0.startsAt.hasPrefix(dayPrefix) && Self.supplementalMatches($0, movie: movie)
            }
            for row in supplemental {
                guard let start = DateFormatter.gracenoteDateTime.date(from: row.startsAt) else { continue }
                let showtime = Showtime(
                    id: "supp-\(row.venue)-\(row.startsAt)",
                    startTime: start,
                    format: row.format,
                    isBargain: false,
                    bookingURL: row.ticketUrl.flatMap(URL.init)
                )
                if let index = theaters.firstIndex(where: {
                    $0.theaterName.caseInsensitiveCompare(row.venue) == .orderedSame
                }) {
                    let existing = theaters[index]
                    guard !existing.showtimes.contains(where: {
                        abs($0.startTime.timeIntervalSince(start)) < 60
                    }) else { continue }
                    theaters[index] = TheaterShowtimes(
                        id: existing.id,
                        theaterName: existing.theaterName,
                        amenities: existing.amenities,
                        showtimes: (existing.showtimes + [showtime])
                            .sorted { $0.startTime < $1.startTime }
                    )
                } else {
                    theaters.append(TheaterShowtimes(
                        id: "supp-\(row.venue)",
                        theaterName: row.venue,
                        amenities: [],
                        showtimes: [showtime]
                    ))
                }
            }
            // A new venue may have arrived with multiple times — re-collapse.
            var merged: [String: TheaterShowtimes] = [:]
            for theater in theaters {
                if let existing = merged[theater.id] {
                    merged[theater.id] = TheaterShowtimes(
                        id: existing.id, theaterName: existing.theaterName,
                        amenities: existing.amenities,
                        showtimes: (existing.showtimes + theater.showtimes)
                            .sorted { $0.startTime < $1.startTime })
                } else {
                    merged[theater.id] = theater
                }
            }
            theaters = Array(merged.values)
        }
        return theaters.sorted { $0.theaterName < $1.theaterName }
    }

    /// One film playing nearby: canonical title (variants merged), year, and
    /// every posted day it has ≥1 showing.
    struct LocalListing: Codable {
        let title: String
        let year: Int?
        let days: Set<Date>
    }

    /// Schedules barely change hour to hour — cache each (zip, start,
    /// radius) window for 6h. Reopening the calendar becomes instant, and
    /// the shared client API key stops being hammered (transient rate
    /// limiting was emptying users' grids).
    private struct CachedSchedule: Codable {
        let savedAt: Date
        let listings: [LocalListing]
    }

    private func scheduleCacheKey(zipcode: String, radius: Int, start: String) -> String {
        "gn.schedule.\(zipcode).\(radius).\(start)"
    }

    private func cachedSchedule(key: String) -> [LocalListing]? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let cached = try? JSONDecoder().decode(CachedSchedule.self, from: data),
              Date().timeIntervalSince(cached.savedAt) < 6 * 3600
        else { return nil }
        return cached.listings
    }

    private func cacheSchedule(_ listings: [LocalListing], key: String) {
        if let data = try? JSONEncoder().encode(CachedSchedule(savedAt: Date(), listings: listings)) {
            UserDefaults.standard.set(data, forKey: key)
        }
        // Evict expired siblings so a season of zip/radius changes doesn't
        // leave orphaned blobs in UserDefaults forever.
        let defaults = UserDefaults.standard
        for staleKey in defaults.dictionaryRepresentation().keys
        where staleKey.hasPrefix("gn.schedule.") && staleKey != key {
            if let data = defaults.data(forKey: staleKey),
               let cached = try? JSONDecoder().decode(CachedSchedule.self, from: data),
               Date().timeIntervalSince(cached.savedAt) >= 6 * 3600 {
                defaults.removeObject(forKey: staleKey)
            } else if defaults.data(forKey: staleKey) == nil {
                defaults.removeObject(forKey: staleKey)
            }
        }
    }

    // MARK: - Supplemental indie venues

    /// Metro key for supplemental indie-venue showtimes, from a US zip.
    /// nil = no supplemental coverage for this area yet. (All v1 venues are
    /// in Manhattan; the prefixes cover the five boroughs + Hudson-county NJ.)
    static func metro(forZip zip: String) -> String? {
        guard zip.count == 5 else { return nil }
        let p3 = String(zip.prefix(3))
        let nyc = ["100", "101", "102", "103", "104", "110", "111", "112",
                   "113", "114", "116", "070", "071", "072", "073"]
        return nyc.contains(p3) ? "nyc" : nil
    }

    private struct CachedSupplemental: Codable {
        let savedAt: Date
        let rows: [SupabaseService.SupplementalShowingRow]
    }

    /// Indie-venue showings for a metro, cached 6h (the server fetcher runs
    /// on the same cadence). Best-effort: a failed fetch returns the stale
    /// cache if any, else [] — Gracenote results must never be blocked on it.
    private func supplementalRows(metro: String) async -> [SupabaseService.SupplementalShowingRow] {
        let key = "supp.\(metro)"
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: key),
           let cached = try? JSONDecoder().decode(CachedSupplemental.self, from: data),
           Date().timeIntervalSince(cached.savedAt) < 6 * 3600 {
            return cached.rows
        }
        guard let rows = try? await SupabaseService.shared.supplementalShowings(metro: metro) else {
            if let data = defaults.data(forKey: key),
               let cached = try? JSONDecoder().decode(CachedSupplemental.self, from: data) {
                return cached.rows
            }
            return []
        }
        if let data = try? JSONEncoder().encode(CachedSupplemental(savedAt: Date(), rows: rows)) {
            defaults.set(data, forKey: key)
        }
        return rows
    }

    private static func yearCompatible(_ a: Int?, _ b: Int?) -> Bool {
        guard let a, let b else { return true }
        return abs(a - b) <= 1
    }

    /// Does a supplemental showing belong to this movie? Strict canonical
    /// title match (venue sites use ALL-CAPS/variant dressing) + year
    /// tolerance when both sides know one.
    static func supplementalMatches(_ row: SupabaseService.SupplementalShowingRow,
                                    movie: Movie) -> Bool {
        normalizeForMatch(canonicalTitle(row.title)) == normalizeForMatch(movie.title)
            && yearCompatible(movie.releaseYear, row.releaseYear)
    }

    /// Union indie-venue showings into the Gracenote slate so calendar marks
    /// match what the venues' own box offices sell.
    static func mergeSupplemental(_ rows: [SupabaseService.SupplementalShowingRow],
                                  into listings: [LocalListing]) -> [LocalListing] {
        guard !rows.isEmpty else { return listings }
        let cal = Calendar.current
        var out = listings
        struct Key: Hashable { let norm: String; let year: Int? }
        var grouped: [Key: (title: String, year: Int?, days: Set<Date>)] = [:]
        for row in rows {
            guard let start = DateFormatter.gracenoteDateTime.date(from: row.startsAt) else { continue }
            let canonical = canonicalTitle(row.title)
            guard !canonical.isEmpty else { continue }
            let key = Key(norm: normalizeForMatch(canonical), year: row.releaseYear)
            var entry = grouped[key] ?? (canonical, row.releaseYear, [])
            entry.days.insert(cal.startOfDay(for: start))
            grouped[key] = entry
        }
        for (key, extra) in grouped {
            if let index = out.firstIndex(where: {
                normalizeForMatch(canonicalTitle($0.title)) == key.norm
                    && yearCompatible($0.year, extra.year)
            }) {
                let existing = out[index]
                out[index] = LocalListing(title: existing.title,
                                          year: existing.year ?? extra.year,
                                          days: existing.days.union(extra.days))
            } else {
                out.append(LocalListing(title: extra.title, year: extra.year, days: extra.days))
            }
        }
        return out
    }

    /// The COMPLETE local slate: every film with a posted showing near this
    /// zip over the posted window, with the days each one plays. This is the
    /// exhaustive source for the "All releases" calendar — Gracenote returns
    /// the whole schedule in one call; variants ("… IMAX") merge into their
    /// canonical film.
    func localSchedule(zipcode: String, radius: Int = 15, days: Int = 14,
                       from start: Date = Date()) async throws -> [LocalListing] {
        let startDay = DateFormatter.localDay.string(from: start)
        let cacheKey = scheduleCacheKey(zipcode: zipcode, radius: radius, start: startDay)
        if let cached = cachedSchedule(key: cacheKey) { return cached }
        // One quiet retry for TRANSIENT failures only — a config error or a
        // bad zip is deterministic and must surface immediately.
        var listings: [GNMovie]
        do {
            listings = try await fetchShowings(zipcode: zipcode, radius: radius,
                                               days: days, start: start)
        } catch let error as ShowtimesError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try await Task.sleep(for: .seconds(1.5))
            listings = try await fetchShowings(zipcode: zipcode, radius: radius,
                                               days: days, start: start)
        }
        let cal = Calendar.current
        var merged: [String: (title: String, year: Int?, days: Set<Date>)] = [:]
        for listing in listings {
            let canonical = Self.canonicalTitle(listing.title)
            guard !canonical.isEmpty else { continue }
            let key = canonical.lowercased() + "|" + (listing.releaseYear.map(String.init) ?? "")
            var entry = merged[key] ?? (canonical, listing.releaseYear, [])
            for showing in listing.showtimes ?? [] {
                guard let start = DateFormatter.gracenoteDateTime
                    .date(from: showing.dateTime ?? "") else { continue }
                entry.days.insert(cal.startOfDay(for: start))
            }
            merged[key] = entry
        }
        var result = merged.values
            .filter { !$0.days.isEmpty }
            .map { LocalListing(title: $0.title, year: $0.year, days: $0.days) }
        // Indie venues publish direct (indie-showtimes fetcher) weeks past
        // their Gracenote feed — union them in so the calendar sells what
        // their box offices sell. Best-effort: a miss caches Gracenote-only.
        if let metro = Self.metro(forZip: zipcode) {
            result = Self.mergeSupplemental(await supplementalRows(metro: metro), into: result)
        }
        cacheSchedule(result, key: cacheKey)
        return result
    }

    /// Which upcoming days does each of these films VERIFIABLY play near this
    /// zip? One Gracenote call covering the posted window (theaters publish
    /// about a week out) answers for all of them — the theater calendar marks
    /// future days from this, so it never claims a day the showtimes sheet
    /// can't back up. Returns tmdbID → set of local days with ≥1 showing.
    func playingDays(for movies: [Movie], zipcode: String, radius: Int = 15,
                     days: Int = 14) async throws -> [Int: Set<Date>] {
        let listings = try await fetchShowings(zipcode: zipcode, radius: radius, days: days)
        var supplemental: [SupabaseService.SupplementalShowingRow] = []
        if let metro = Self.metro(forZip: zipcode) {
            supplemental = await supplementalRows(metro: metro)
        }
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
            // Indie venues too — a saved movie's one-off repertory screening
            // must mark the calendar like any chain showing.
            for row in supplemental where Self.supplementalMatches(row, movie: movie) {
                guard let start = DateFormatter.gracenoteDateTime.date(from: row.startsAt) else { continue }
                result[movie.tmdbID, default: []].insert(cal.startOfDay(for: start))
            }
        }
        return result
    }

    /// The raw multi-day showings feed for a zip — shared by every consumer
    /// so the query (and its clamps) can't drift between them.
    private func fetchShowings(zipcode: String, radius: Int, days: Int,
                               start: Date = Date()) async throws -> [GNMovie] {
        guard let apiKey = AppConfig.showtimesAPIKey else {
            throw ShowtimesError.notConfigured
        }
        var components = URLComponents(string: "https://data.tmsapi.com/v1.1/movies/showings") ?? URLComponents()
        components.queryItems = [
            URLQueryItem(name: "startDate", value: DateFormatter.localDay.string(from: start)),
            URLQueryItem(name: "numDays", value: String(max(1, min(days, 14)))),
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
        // 200 + zero bytes is Gracenote's normal "no theaters here" (see
        // showtimes(for:)) — an empty slate, not an error to retry.
        guard !data.isEmpty else { return [] }
        return try JSONDecoder().decode([GNMovie].self, from: data)
    }

    /// Find our film among everything playing nearby. Gracenote lists
    /// premium screenings as SEPARATE title variants ("…: The IMAX 2D
    /// Experience", "… 70mm", "… (25th Anniversary)"), so score against
    /// the CANONICAL title and merge every matching variant — otherwise
    /// the IMAX showings simply vanish.
    /// Lowercased, diacritic-folded, alphanumeric-word form for equality
    /// checks ("WALL·E" == "WALL-E").
    private static func normalizeForMatch(_ title: String) -> String {
        title.lowercased()
            .folding(options: [.diacriticInsensitive], locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func variantMatches(for movie: Movie, in listings: [GNMovie]) -> [GNMovie] {
        let movieNorm = normalizeForMatch(movie.title)
        let scored = listings.map { listing -> (GNMovie, Double) in
            // Year gating, aligned with the calendar's resolver so the grid
            // and this sheet can never disagree about the same listing:
            // - exact canonical-title match: tolerate up to 3 years of
            //   Gracenote(US release year) vs TMDB(premiere year) drift
            // - anything else >1 year apart = a DIFFERENT film, full stop
            //   ("The Lion King" 1994 vs the 2019 remake share a title; a
            //   soft malus once let the wrong film's showtimes through)
            if let want = movie.releaseYear, let got = listing.releaseYear,
               abs(want - got) > 1 {
                let exactTitle = normalizeForMatch(canonicalTitle(listing.title)) == movieNorm
                if !(exactTitle && abs(want - got) <= 3) {
                    return (listing, -1)
                }
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
