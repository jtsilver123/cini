import Foundation
import CoreLocation

/// Showtimes near a zipcode — Cini's analog of Beli's "Reserve now".
///
/// Theatrical showtime data has no truly open API; this service is built
/// around a small protocol so the backing provider can be swapped. The
/// default implementation targets MovieGlu (https://developer.movieglu.com),
/// which offers a free developer tier. Without credentials the UI shows a
/// graceful empty state instead of failing.
protocol ShowtimesProviding {
    func showtimes(for movieTitle: String, zipcode: String, date: Date) async throws -> [TheaterShowtimes]
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
    let format: String?      // "IMAX", "Dolby", "Standard"
    let bookingURL: URL?
}

enum ShowtimesError: Error {
    case notConfigured
    case zipcodeNotFound
}

final class ShowtimesService: ShowtimesProviding {
    static let shared = ShowtimesService()

    private let session = URLSession.shared
    private let geocoder = CLGeocoder()

    func showtimes(for movieTitle: String, zipcode: String, date: Date) async throws -> [TheaterShowtimes] {
        guard let apiKey = AppConfig.showtimesAPIKey,
              let authorization = AppConfig.showtimesAuthorization else {
            throw ShowtimesError.notConfigured
        }

        // MovieGlu keys off lat/long; resolve the zipcode locally first.
        guard let placemark = try await geocoder.geocodeAddressString(zipcode).first,
              let location = placemark.location else {
            throw ShowtimesError.zipcodeNotFound
        }
        let geolocation = String(format: "%.4f;%.4f",
                                 location.coordinate.latitude, location.coordinate.longitude)

        // 1. Resolve the film in MovieGlu's catalog.
        guard let film: FilmLiveSearch.Film = try await request(
            path: "filmLiveSearch", query: ["query": movieTitle, "n": "1"],
            apiKey: apiKey, authorization: authorization, geolocation: geolocation,
            transform: { (r: FilmLiveSearch) in r.films.first }
        ) else { return [] }

        // 2. Fetch showtimes near the location.
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let response: FilmShowTimes = try await request(
            path: "filmShowTimes",
            query: ["film_id": String(film.filmId), "date": formatter.string(from: date), "n": "10"],
            apiKey: apiKey, authorization: authorization, geolocation: geolocation,
            transform: { $0 }
        )

        return response.cinemas.map { cinema in
            TheaterShowtimes(
                id: String(cinema.cinemaId),
                theaterName: cinema.cinemaName,
                address: cinema.address ?? "",
                distanceMiles: cinema.distance,
                showtimes: cinema.allTimes.compactMap { time in
                    guard let start = Self.parseTime(time.startTime, on: date) else { return nil }
                    return Showtime(
                        id: "\(cinema.cinemaId)-\(time.startTime)",
                        startTime: start,
                        format: time.format,
                        bookingURL: nil
                    )
                }
            )
        }
    }

    private static func parseTime(_ hhmm: String, on day: Date) -> Date? {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }

    private func request<R: Decodable, T>(
        path: String, query: [String: String],
        apiKey: String, authorization: String, geolocation: String,
        transform: (R) -> T
    ) async throws -> T {
        var components = URLComponents(string: "https://api-gate2.movieglu.com/\(path)/")!
        components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        request.setValue("CINI", forHTTPHeaderField: "client")
        request.setValue("US", forHTTPHeaderField: "territory")
        request.setValue("v200", forHTTPHeaderField: "api-version")
        request.setValue(geolocation, forHTTPHeaderField: "geolocation")
        request.setValue(ISO8601DateFormatter().string(from: Date()), forHTTPHeaderField: "device-datetime")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return transform(try decoder.decode(R.self, from: data))
    }
}

// MARK: - MovieGlu DTOs

private struct FilmLiveSearch: Decodable {
    struct Film: Decodable {
        let filmId: Int
        let filmName: String
    }
    let films: [Film]
}

private struct FilmShowTimes: Decodable {
    struct Cinema: Decodable {
        struct Showings: Decodable {
            struct TimeEntry: Decodable {
                let startTime: String
            }
            let times: [TimeEntry]
        }
        let cinemaId: Int
        let cinemaName: String
        let address: String?
        let distance: Double?
        let showings: [String: Showings]?

        var allTimes: [(startTime: String, format: String?)] {
            (showings ?? [:]).flatMap { kind, showing in
                showing.times.map { ($0.startTime, kind == "Standard" ? nil : kind) }
            }
            .sorted { $0.startTime < $1.startTime }
        }
    }
    let cinemas: [Cinema]
}
