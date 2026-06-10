import Foundation

/// TMDB API client: search, details, credits, watch providers, trending,
/// similar titles. Responses are cached via URLCache; movie metadata is
/// additionally upserted into Supabase's `movies` table by RankingStore.
final class TMDBService {
    static let shared = TMDBService()

    enum ImageSize: String {
        case poster = "w342"
        case backdrop = "w780"
        case profile = "w185"
    }

    static func imageURL(path: String?, size: ImageSize) -> URL? {
        guard let path else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/\(size.rawValue)\(path)")
    }

    private let session: URLSession
    private let apiKey: String

    init(apiKey: String = AppConfig.tmdbAPIKey) {
        self.apiKey = apiKey
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024,
            diskPath: "cini-tmdb"
        )
        config.requestCachePolicy = .returnCacheDataElseLoad
        session = URLSession(configuration: config)
    }

    // MARK: - Endpoints

    func search(query: String, year: Int? = nil) async throws -> [Movie] {
        var items = [URLQueryItem(name: "query", value: query)]
        if let year { items.append(URLQueryItem(name: "primary_release_year", value: String(year))) }
        let page: SearchPage = try await get("/search/movie", query: items, cachePolicy: .reloadIgnoringLocalCacheData)
        return page.results.map(\.asMovie)
    }

    func trending() async throws -> [Movie] {
        let page: SearchPage = try await get("/trending/movie/week")
        return page.results.map(\.asMovie)
    }

    func popular(year: Int? = nil) async throws -> [Movie] {
        var items: [URLQueryItem] = [URLQueryItem(name: "sort_by", value: "popularity.desc")]
        if let year { items.append(URLQueryItem(name: "primary_release_year", value: String(year))) }
        let page: SearchPage = try await get("/discover/movie", query: items)
        return page.results.map(\.asMovie)
    }

    func similar(to movieID: Int) async throws -> [Movie] {
        let page: SearchPage = try await get("/movie/\(movieID)/similar")
        return page.results.map(\.asMovie)
    }

    /// Full detail with credits and US certification in one round trip.
    func details(for movieID: Int) async throws -> Movie {
        let detail: DetailDTO = try await get(
            "/movie/\(movieID)",
            query: [URLQueryItem(name: "append_to_response", value: "credits,release_dates")]
        )
        return detail.asMovie
    }

    func cast(for movieID: Int) async throws -> [CastMember] {
        let credits: CreditsDTO = try await get("/movie/\(movieID)/credits")
        return credits.cast
    }

    /// Watch providers for "Where to Watch" (US region by default).
    func watchProviders(for movieID: Int, region: String = "US") async throws -> WatchProviders {
        let response: ProvidersResponse = try await get("/movie/\(movieID)/watch/providers")
        return response.results[region] ?? WatchProviders(link: nil, flatrate: nil, rent: nil, buy: nil)
    }

    func trailerURL(for movieID: Int) async throws -> URL? {
        let videos: VideosDTO = try await get("/movie/\(movieID)/videos")
        let trailer = videos.results.first { $0.site == "YouTube" && $0.type == "Trailer" }
            ?? videos.results.first { $0.site == "YouTube" }
        return trailer.flatMap { URL(string: "https://www.youtube.com/watch?v=\($0.key)") }
    }

    // MARK: - Transport

    private func get<T: Decodable>(
        _ path: String,
        query: [URLQueryItem] = [],
        cachePolicy: URLRequest.CachePolicy = .returnCacheDataElseLoad
    ) async throws -> T {
        var components = URLComponents(string: "https://api.themoviedb.org/3" + path)!
        components.queryItems = query + [URLQueryItem(name: "api_key", value: apiKey)]
        var request = URLRequest(url: components.url!)
        request.cachePolicy = cachePolicy
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(T.self, from: data)
    }
}

// MARK: - DTOs

struct CastMember: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let character: String?
    let profilePath: String?

    var photoURL: URL? { TMDBService.imageURL(path: profilePath, size: .profile) }
}

struct WatchProviders: Codable, Hashable {
    struct Provider: Codable, Identifiable, Hashable {
        let providerId: Int
        let providerName: String
        let logoPath: String?

        var id: Int { providerId }
        var logoURL: URL? { TMDBService.imageURL(path: logoPath, size: .profile) }
    }

    /// TMDB attribution link — deep-link target for provider rows.
    let link: String?
    let flatrate: [Provider]?
    let rent: [Provider]?
    let buy: [Provider]?

    var streamingNames: [String] { (flatrate ?? []).map(\.providerName) }
}

private struct SearchPage: Codable {
    let results: [MovieDTO]
}

private struct MovieDTO: Codable {
    let id: Int
    let title: String
    let releaseDate: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let genreIds: [Int]?
    let originalLanguage: String?

    var asMovie: Movie {
        Movie(
            tmdbID: id,
            mediaKind: "movie",
            title: title,
            releaseYear: releaseDate.flatMap { Int($0.prefix(4)) },
            posterPath: posterPath,
            backdropPath: backdropPath,
            genres: (genreIds ?? []).compactMap { Self.genreNames[$0] },
            certification: nil,
            runtimeMinutes: nil,
            director: nil,
            overview: overview,
            originalLanguage: originalLanguage
        )
    }

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
    ]
}

private struct DetailDTO: Codable {
    struct Genre: Codable { let name: String }
    struct ReleaseDates: Codable {
        struct Entry: Codable {
            struct Release: Codable { let certification: String }
            let iso31661: String
            let releaseDates: [Release]
        }
        let results: [Entry]
    }

    let id: Int
    let title: String
    let releaseDate: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let runtime: Int?
    let genres: [Genre]
    let originalLanguage: String?
    let credits: CreditsDTO?
    let releaseDates: ReleaseDates?

    var asMovie: Movie {
        let usCert = releaseDates?.results
            .first { $0.iso31661 == "US" }?
            .releaseDates.map(\.certification)
            .first { !$0.isEmpty }
        return Movie(
            tmdbID: id,
            mediaKind: "movie",
            title: title,
            releaseYear: releaseDate.flatMap { Int($0.prefix(4)) },
            posterPath: posterPath,
            backdropPath: backdropPath,
            genres: genres.map(\.name).map { $0 == "Science Fiction" ? "Sci-Fi" : $0 },
            certification: usCert,
            runtimeMinutes: runtime,
            director: credits?.crew.first { $0.job == "Director" }?.name,
            overview: overview,
            originalLanguage: originalLanguage
        )
    }
}

struct CreditsDTO: Codable {
    struct CrewMember: Codable {
        let name: String
        let job: String?
    }

    let cast: [CastMember]
    let crew: [CrewMember]
}

private struct VideosDTO: Codable {
    struct Video: Codable {
        let key: String
        let site: String
        let type: String
    }
    let results: [Video]
}

private struct ProvidersResponse: Codable {
    let results: [String: WatchProviders]
}
