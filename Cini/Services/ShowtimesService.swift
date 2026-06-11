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

    private let session = URLSession.shared

    func showtimes(for movie: Movie, zipcode: String, date: Date) async throws -> [TheaterShowtimes] {
        guard let apiKey = AppConfig.showtimesAPIKey else {
            throw ShowtimesError.notConfigured
        }
        // TV shows (negative ids) have no theatrical showtimes — a fuzzy
        // match against whatever's playing would invent some.
        guard movie.tmdbID > 0 else { return [] }

        let day = DateFormatter.posixDay.string(from: date)
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

        // Find our film among everything playing nearby: best fuzzy title
        // match, with the release year as a strong signal.
        let best = listings
            .map { listing -> (GNMovie, Double) in
                var score = Fuzzy.similarity(query: movie.title, candidate: listing.title)
                if let want = movie.releaseYear, let got = listing.releaseYear {
                    score += want == got ? 0.15 : (abs(want - got) > 1 ? -0.25 : 0)
                }
                return (listing, score)
            }
            .max { $0.1 < $1.1 }
        guard let (match, score) = best, score > 0.6 else { return [] }

        // Group its showtimes by theatre, collecting seat-comfort perks.
        var byTheatre: [String: (name: String, perks: Set<String>, times: [Showtime])] = [:]
        for showing in match.showtimes ?? [] {
            guard let theatre = showing.theatre,
                  let start = DateFormatter.gracenoteDateTime.date(from: showing.dateTime ?? "") else { continue }
            let key = theatre.id ?? theatre.name ?? "?"
            let entry = Showtime(
                id: "\(key)-\(showing.dateTime ?? "")",
                startTime: start,
                format: showing.format,
                isBargain: showing.barg ?? false,
                bookingURL: showing.secureTicketURL
            )
            var bucket = byTheatre[key] ?? (theatre.name ?? "Theater", [], [])
            bucket.name = theatre.name ?? bucket.name
            bucket.perks.formUnion(showing.perks)
            bucket.times.append(entry)
            byTheatre[key] = bucket
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

        /// Premium screen format, if any ("IMAX", "4DX", "Dolby", …).
        var format: String? {
            let premiums = ["IMAX", "4DX", "RPX", "ScreenX", "70mm",
                            "Dolby", "ATMOS", "3D", "Laser"]
            for premium in premiums
            where qualList.contains(where: { $0.localizedCaseInsensitiveContains(premium) }) {
                return premium == "ATMOS" ? "Dolby Atmos"
                     : premium == "Laser" ? "Laser" : premium
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
