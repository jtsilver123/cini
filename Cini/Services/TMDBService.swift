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

    /// TV shows ride the same Int plumbing as movies by using NEGATIVE
    /// tmdb ids (the two id spaces overlap at TMDB). A show is ranked as
    /// a whole — never per season or episode.
    static func mediaPath(_ id: Int, suffix: String = "") -> String {
        (id < 0 ? "/tv/\(-id)" : "/movie/\(id)") + suffix
    }

    func search(query: String, year: Int? = nil, page: Int = 1) async throws -> [Movie] {
        let items = [URLQueryItem(name: "query", value: query),
                     URLQueryItem(name: "page", value: String(page))]
        // multi = movies + TV in one call (people filtered out in mapping)
        let result: MultiSearchPage = try await get("/search/multi", query: items, cachePolicy: .reloadIgnoringLocalCacheData)
        var movies = result.results.compactMap(\.asMovie)
        if let year {
            movies = movies.filter { $0.releaseYear == nil || $0.releaseYear == year }
        }
        return movies
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

    /// Human-readable theme keywords ("space opera", "heist") — the tag
    /// fallback before any Cini member has labeled the movie.
    func keywords(for movieID: Int) async throws -> [String] {
        struct KeywordsPage: Codable {
            struct Keyword: Codable { let name: String }
            let movieKeywords: [Keyword]?
            let tvKeywords: [Keyword]?
            var keywords: [Keyword] { movieKeywords ?? tvKeywords ?? [] }
            enum CodingKeys: String, CodingKey {
                case movieKeywords = "keywords"
                case tvKeywords = "results"
            }
        }
        let page: KeywordsPage = try await get(Self.mediaPath(movieID, suffix: "/keywords"))
        return page.keywords
            .map(\.name.localizedCapitalized)
            .filter { $0.count <= 22 }
    }

    /// Theatrical releases coming soon (release calendar).
    func upcoming() async throws -> [Movie] {
        let page: SearchPage = try await get("/movie/upcoming", query: [URLQueryItem(name: "region", value: "US")])
        return page.results.map(\.asMovie)
    }

    func similar(to movieID: Int) async throws -> [Movie] {
        let page: SearchPage = try await get("/movie/\(movieID)/similar")
        return page.results.map(\.asMovie)
    }

    /// Full detail with credits and US certification in one round trip.
    func details(for movieID: Int) async throws -> Movie {
        if movieID < 0 {
            let detail: TVDetailDTO = try await get(Self.mediaPath(movieID),
                query: [URLQueryItem(name: "append_to_response", value: "credits")])
            return detail.asMovie
        }
        let detail: DetailDTO = try await get(
            "/movie/\(movieID)",
            query: [URLQueryItem(name: "append_to_response", value: "credits,release_dates")]
        )
        return detail.asMovie
    }

    func cast(for movieID: Int) async throws -> [CastMember] {
        let credits: CreditsDTO = try await get(Self.mediaPath(movieID, suffix: "/credits"))
        return credits.cast
    }

    /// Watch providers for "Where to Watch" (US region by default).
    func watchProviders(for movieID: Int, region: String = "US") async throws -> WatchProviders {
        let response: ProvidersResponse = try await get(Self.mediaPath(movieID, suffix: "/watch/providers"))
        return response.results[region] ?? WatchProviders(link: nil, flatrate: nil, rent: nil, buy: nil)
    }

    func trailerURL(for movieID: Int) async throws -> URL? {
        let videos: VideosDTO = try await get(Self.mediaPath(movieID, suffix: "/videos"))
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

/// /search/multi rows: movies, TV shows, and people (people are dropped).
private struct MultiSearchPage: Codable {
    let results: [MultiDTO]
}

private struct MultiDTO: Codable {
    let id: Int
    let mediaType: String?
    // movie fields
    let title: String?
    let releaseDate: String?
    // tv fields
    let name: String?
    let firstAirDate: String?
    // shared
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let genreIds: [Int]?
    let originalLanguage: String?
    let popularity: Double?

    var asMovie: Movie? {
        switch mediaType {
        case "movie":
            guard let title else { return nil }
            return Movie(
                tmdbID: id, mediaKind: "movie", title: title,
                releaseYear: releaseDate.flatMap { Int($0.prefix(4)) },
                posterPath: posterPath, backdropPath: backdropPath,
                genres: (genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                certification: nil, runtimeMinutes: nil, director: nil,
                overview: overview, originalLanguage: originalLanguage,
                popularity: popularity, releaseDateFull: releaseDate
            )
        case "tv":
            guard let name else { return nil }
            // Negative id keeps TV out of the movie id space everywhere.
            return Movie(
                tmdbID: -id, mediaKind: "tv", title: name,
                releaseYear: firstAirDate.flatMap { Int($0.prefix(4)) },
                posterPath: posterPath, backdropPath: backdropPath,
                genres: (genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                certification: nil, runtimeMinutes: nil, director: nil,
                overview: overview, originalLanguage: originalLanguage,
                popularity: popularity, releaseDateFull: firstAirDate
            )
        default:
            return nil   // person results
        }
    }
}

/// Whole-show TV detail mapped onto the Movie shape (negative id).
private struct TVDetailDTO: Codable {
    struct Genre: Codable { let name: String }
    struct Creator: Codable { let name: String }
    let id: Int
    let name: String
    let firstAirDate: String?
    let posterPath: String?
    let backdropPath: String?
    let overview: String?
    let genres: [Genre]?
    let episodeRunTime: [Int]?
    let createdBy: [Creator]?
    let numberOfSeasons: Int?
    let originalLanguage: String?
    let popularity: Double?

    var asMovie: Movie {
        Movie(
            tmdbID: -id, mediaKind: "tv", title: name,
            releaseYear: firstAirDate.flatMap { Int($0.prefix(4)) },
            posterPath: posterPath, backdropPath: backdropPath,
            genres: (genres ?? []).map(\.name),
            certification: numberOfSeasons.map { "\($0) season\($0 == 1 ? "" : "s")" },
            runtimeMinutes: episodeRunTime?.first,
            director: createdBy?.first?.name,
            overview: overview, originalLanguage: originalLanguage,
            popularity: popularity, releaseDateFull: firstAirDate
        )
    }
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
    let popularity: Double?

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
            originalLanguage: originalLanguage,
            popularity: popularity,
            releaseDateFull: releaseDate
        )
    }

    static let genreNames: [Int: String] = [
        28: "Action", 12: "Adventure", 16: "Animation", 35: "Comedy", 80: "Crime",
        99: "Documentary", 18: "Drama", 10751: "Family", 14: "Fantasy", 36: "History",
        27: "Horror", 10402: "Music", 9648: "Mystery", 10749: "Romance",
        878: "Sci-Fi", 10770: "TV Movie", 53: "Thriller", 10752: "War", 37: "Western",
        // TV genre ids
        10759: "Action", 10762: "Kids", 10763: "News", 10764: "Reality",
        10765: "Sci-Fi", 10766: "Soap", 10767: "Talk", 10768: "War",
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
