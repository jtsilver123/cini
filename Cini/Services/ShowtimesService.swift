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
    let address: String
    let distanceMiles: Double?
    let showtimes: [Showtime]
}

struct Showtime: Identifiable, Hashable {
    let id: String
    let startTime: Date
    let format: String?      // "IMAX", "3D", …
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

        let day = DateFormatter.gracenoteDay.string(from: date)
        var components = URLComponents(string: "https://data.tmsapi.com/v1.1/movies/showings")!
        components.queryItems = [
            URLQueryItem(name: "startDate", value: day),
            URLQueryItem(name: "zip", value: zipcode),
            URLQueryItem(name: "radius", value: "15"),
            URLQueryItem(name: "units", value: "mi"),
            URLQueryItem(name: "api_key", value: apiKey),
        ]
        let (data, response) = try await session.data(from: components.url!)
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

        // Group its showtimes by theatre.
        var byTheatre: [String: (name: String, times: [Showtime])] = [:]
        for showing in match.showtimes ?? [] {
            guard let theatre = showing.theatre,
                  let start = DateFormatter.gracenoteDateTime.date(from: showing.dateTime ?? "") else { continue }
            let entry = Showtime(
                id: "\(theatre.id ?? "?")-\(showing.dateTime ?? "")",
                startTime: start,
                format: showing.format,
                bookingURL: showing.ticketURI.flatMap(URL.init)
            )
            byTheatre[theatre.id ?? theatre.name ?? "?", default: (theatre.name ?? "Theater", [])].times.append(entry)
            byTheatre[theatre.id ?? theatre.name ?? "?"]?.name = theatre.name ?? "Theater"
        }

        return byTheatre
            .map { id, value in
                TheaterShowtimes(
                    id: id,
                    theaterName: value.name,
                    address: "",
                    distanceMiles: nil,
                    showtimes: value.times.sorted { $0.startTime < $1.startTime }
                )
            }
            .sorted { $0.theaterName < $1.theaterName }
    }
}

private extension DateFormatter {
    static let gracenoteDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// "2026-06-11T19:30" — local time, no zone or seconds.
    static let gracenoteDateTime: DateFormatter = {
        let f = DateFormatter()
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

        /// Surface premium formats only ("IMAX", "3D", "Dolby").
        var format: String? {
            guard let quals else { return nil }
            for premium in ["IMAX", "3D", "Dolby"] where quals.localizedCaseInsensitiveContains(premium) {
                return premium
            }
            return nil
        }
    }

    let title: String
    let releaseYear: Int?
    let showtimes: [Showing]?
}
