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
        // Fail fast on dead networks — 60s default feels like a hang.
        config.timeoutIntervalForRequest = 20
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
        // /trending/all: movies AND shows, like the conversation actually is.
        let page: MultiSearchPage = try await get("/trending/all/week")
        return page.results.compactMap(\.asMovie)
    }

    /// Popular movies AND shows, merged by popularity — TV is first-class.
    func popular(year: Int? = nil) async throws -> [Movie] {
        var movieItems: [URLQueryItem] = [URLQueryItem(name: "sort_by", value: "popularity.desc")]
        var tvItems: [URLQueryItem] = [URLQueryItem(name: "sort_by", value: "popularity.desc")]
        if let year {
            movieItems.append(URLQueryItem(name: "primary_release_year", value: String(year)))
            tvItems.append(URLQueryItem(name: "first_air_date_year", value: String(year)))
        }
        async let moviePage: SearchPage = get("/discover/movie", query: movieItems)
        async let tvPage: TVListPage = get("/discover/tv", query: tvItems)
        let movies = (try await moviePage).results.map(\.asMovie)
        // A TV hiccup shouldn't blank the whole Popular tab.
        let shows = ((try? await tvPage)?.results ?? []).map(\.asMovie)
        var merged = movies + shows
        merged.sort { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        return merged
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

    /// Theatrical releases landing in ONE calendar month — lets the release
    /// calendar page arbitrarily far ahead and fill each month on arrival
    /// (the /movie/upcoming window only covers the next few weeks).
    func releases(in month: Date) async throws -> [Movie] {
        let cal = Calendar.current
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: DateComponents(month: 1, day: -1), to: start)
        else { return [] }
        let q = [
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "primary_release_date.gte", value: DateFormatter.localDay.string(from: start)),
            URLQueryItem(name: "primary_release_date.lte", value: DateFormatter.localDay.string(from: end)),
            URLQueryItem(name: "region", value: "US"),
        ]
        // Two pages: one only covers the ~20 most popular — a paged-to month
        // deserves the same exhaustiveness as the near term.
        async let first: SearchPage = get("/discover/movie", query: q + [URLQueryItem(name: "page", value: "1")])
        async let second: SearchPage = get("/discover/movie", query: q + [URLQueryItem(name: "page", value: "2")])
        let a = (try await first).results.map(\.asMovie)
        let b = ((try? await second)?.results ?? []).map(\.asMovie)
        return a + b
    }

    /// The classics most people have actually seen — sorted by vote count, so
    /// the all-time, widely-watched titles surface first (CIN-34 "Popular").
    func mostWatched() async throws -> [Movie] {
        let q = [URLQueryItem(name: "sort_by", value: "vote_count.desc")]
        async let moviePage: SearchPage = get("/discover/movie", query: q)
        async let tvPage: TVListPage = get("/discover/tv", query: q)
        let movies = (try await moviePage).results.map(\.asMovie)
        let shows = ((try? await tvPage)?.results ?? []).map(\.asMovie)
        return movies + shows
    }

    /// Titles that are out NOW — recently released (on or before today),
    /// newest first, with enough votes to be real (CIN-34 "Release").
    func nowOut() async throws -> [Movie] {
        let today = DateFormatter.localDay.string(from: Date())
        let movieQ = [
            URLQueryItem(name: "sort_by", value: "primary_release_date.desc"),
            URLQueryItem(name: "primary_release_date.lte", value: today),
            URLQueryItem(name: "vote_count.gte", value: "40"),
        ]
        let tvQ = [
            URLQueryItem(name: "sort_by", value: "first_air_date.desc"),
            URLQueryItem(name: "first_air_date.lte", value: today),
            URLQueryItem(name: "vote_count.gte", value: "20"),
        ]
        async let moviePage: SearchPage = get("/discover/movie", query: movieQ)
        async let tvPage: TVListPage = get("/discover/tv", query: tvQ)
        let movies = (try await moviePage).results.map(\.asMovie)
        let shows = ((try? await tvPage)?.results ?? []).map(\.asMovie)
        var merged = movies + shows
        merged.sort { ($0.releaseDateFull ?? "") > ($1.releaseDateFull ?? "") }
        return merged
    }

    /// Similar titles for movies AND shows (negative ids → /tv/).
    func similar(to movieID: Int) async throws -> [Movie] {
        if movieID < 0 {
            let page: TVListPage = try await get("/tv/\(-movieID)/similar")
            return page.results.map(\.asMovie)
        }
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

    /// Letterboxd-style "Details" facts: studio, country, language,
    /// release date. TV uses networks/first-air-date.
    struct ExtendedDetails {
        var studios: [String] = []
        var countries: [String] = []
        var languages: [String] = []
        var releaseDate: String?   // "2024-03-01"
        // For ongoing shows: when the next episode/season airs.
        var nextEpisodeAirDate: String?   // "2024-06-20"
        var nextEpisodeSeason: Int?
        var nextEpisodeNumber: Int?
        // Show structure, for bounding the "currently watching" steppers.
        var numberOfSeasons: Int?
        var seasonEpisodeCounts: [Int: Int] = [:]   // season number → episode count
        var lastAiredSeason: Int?                    // latest episode that has aired
        var lastAiredEpisode: Int?
        var status: String?                          // "Ended"/"Canceled" vs "Returning Series" etc.
    }

    func extendedDetails(for movieID: Int) async throws -> ExtendedDetails {
        struct Named: Codable { let name: String }
        struct Lang: Codable { let englishName: String?; let name: String? }
        struct Ep: Codable { let airDate: String?; let seasonNumber: Int?; let episodeNumber: Int? }
        struct SeasonDTO: Codable { let seasonNumber: Int?; let episodeCount: Int? }
        struct DTO: Codable {
            let productionCompanies: [Named]?
            let networks: [Named]?
            let productionCountries: [Named]?
            let spokenLanguages: [Lang]?
            let releaseDate: String?
            let firstAirDate: String?
            let nextEpisodeToAir: Ep?
            let lastEpisodeToAir: Ep?
            let numberOfSeasons: Int?
            let seasons: [SeasonDTO]?
            let status: String?
        }
        let dto: DTO = try await get(Self.mediaPath(movieID))
        var studios = (dto.productionCompanies ?? []).map(\.name)
        if studios.isEmpty { studios = (dto.networks ?? []).map(\.name) }
        var counts: [Int: Int] = [:]
        for s in dto.seasons ?? [] {
            if let n = s.seasonNumber, n >= 1, let c = s.episodeCount { counts[n] = c }
        }
        return ExtendedDetails(
            studios: studios,
            countries: (dto.productionCountries ?? []).map(\.name),
            languages: (dto.spokenLanguages ?? []).compactMap { $0.englishName ?? $0.name },
            releaseDate: dto.releaseDate ?? dto.firstAirDate,
            nextEpisodeAirDate: dto.nextEpisodeToAir?.airDate,
            nextEpisodeSeason: dto.nextEpisodeToAir?.seasonNumber,
            nextEpisodeNumber: dto.nextEpisodeToAir?.episodeNumber,
            numberOfSeasons: dto.numberOfSeasons,
            seasonEpisodeCounts: counts,
            lastAiredSeason: dto.lastEpisodeToAir?.seasonNumber,
            lastAiredEpisode: dto.lastEpisodeToAir?.episodeNumber,
            status: dto.status
        )
    }

    /// One episode's title + synopsis — the little recap under the Currently
    /// Watching steppers. `showID` is the app's signed id (negative for TV).
    struct EpisodeInfo { var name: String?; var overview: String? }
    func episode(showID: Int, season: Int, episode: Int) async throws -> EpisodeInfo {
        struct DTO: Codable { let name: String?; let overview: String? }
        let dto: DTO = try await get(Self.mediaPath(showID, suffix: "/season/\(season)/episode/\(episode)"))
        return EpisodeInfo(name: dto.name, overview: dto.overview)
    }

    // MARK: - Genre & director queries (first-class search inputs)

    /// Movie-genre id whose name matches the query ("horror", "sci fi",
    /// "science fiction", "comdey"…) — nil when the query isn't a genre.
    static func genreID(matching query: String) -> Int? {
        let q = query.lowercased().filter(\.isLetter)
        guard q.count >= 3 else { return nil }
        if q == "sciencefiction" || q == "scifi" { return 878 }
        let movieGenres = [28, 12, 16, 35, 80, 99, 18, 10751, 14, 36, 27,
                           10402, 9648, 10749, 878, 53, 10752, 37]
        for id in movieGenres {
            guard let name = MovieDTO.genreNames[id] else { continue }
            let n = name.lowercased().filter(\.isLetter)
            if n == q { return id }
            if q.count >= 5, Fuzzy.similarity(query: q, candidate: n) >= 0.85 { return id }
        }
        return nil
    }

    /// TMDB's TV endpoints use DIFFERENT genre ids for several genres — the
    /// movie ids return ZERO shows (verified live: Action 28, Adventure 12,
    /// Fantasy 14, Sci-Fi 878, Thriller 53, War 10752, Horror 27, Music 10402
    /// all come back empty on /discover/tv). Map to the TV counterpart so
    /// Movies and TV filter identically; ids without a distinct TV genre pass
    /// through unchanged (Comedy, Drama, Crime… share ids; Romance/History
    /// still resolve via TMDB's legacy tagging).
    static func tvGenreID(_ movieGenreID: Int) -> Int {
        switch movieGenreID {
        case 28, 12: return 10759      // Action, Adventure → Action & Adventure
        case 14, 878: return 10765     // Fantasy, Science Fiction → Sci-Fi & Fantasy
        case 27, 53: return 9648       // Horror, Thriller → Mystery (TMDB's TV proxy)
        case 10752: return 10768       // War → War & Politics
        default: return movieGenreID
        }
    }

    /// TMDB watch-provider ids (US) for the major services the filter offers.
    static func providerID(_ name: String) -> Int? {
        switch name {
        case "Netflix": return 8
        case "Prime Video": return 9
        case "Hulu": return 15
        case "Disney+": return 337
        case "Apple TV+": return 350
        case "Peacock": return 386
        case "Max": return 1899
        case "Paramount+": return 531
        default: return nil
        }
    }

    /// A filter-driven pool (the Swipe page): TMDB /discover for the chosen
    /// genre / decade / max-runtime / streaming provider. `wantTV` picks the
    /// movie vs TV endpoint. Adjusting a filter fetches a fresh, matching pool
    /// instead of narrowing a fixed one.
    func discover(genre: String?, decade: Int?, maxRuntime: Int?,
                  provider: String?, wantTV: Bool) async throws -> [Movie] {
        var q: [URLQueryItem] = [
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
            URLQueryItem(name: "vote_count.gte", value: "25"),
        ]
        if let genre, let gid = Self.genreID(matching: genre) {
            q.append(URLQueryItem(name: "with_genres",
                                  value: String(wantTV ? Self.tvGenreID(gid) : gid)))
        }
        if let decade {
            let lo = "\(decade)-01-01", hi = "\(decade + 9)-12-31"
            let key = wantTV ? "first_air_date" : "primary_release_date"
            q.append(URLQueryItem(name: "\(key).gte", value: lo))
            q.append(URLQueryItem(name: "\(key).lte", value: hi))
        }
        if let maxRuntime, !wantTV {
            q.append(URLQueryItem(name: "with_runtime.lte", value: String(maxRuntime)))
        }
        if let provider, let pid = Self.providerID(provider) {
            q.append(URLQueryItem(name: "with_watch_providers", value: String(pid)))
            q.append(URLQueryItem(name: "watch_region", value: "US"))
            q.append(URLQueryItem(name: "with_watch_monetization_types", value: "flatrate"))
        }
        if wantTV {
            let page: TVListPage = try await get("/discover/tv", query: q)
            return page.results.map(\.asMovie)
        }
        let page: SearchPage = try await get("/discover/movie", query: q)
        return page.results.map(\.asMovie)
    }

    /// Most popular titles in a genre — what a genre query should return.
    /// Movies and TV both, interleaved by popularity (golden rule: the two
    /// content types get identical treatment on every surface).
    func popular(genreID: Int) async throws -> [Movie] {
        async let moviePage: SearchPage = get("/discover/movie", query: [
            URLQueryItem(name: "with_genres", value: String(genreID)),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
        ])
        async let tvPage: TVListPage = get("/discover/tv", query: [
            URLQueryItem(name: "with_genres", value: String(Self.tvGenreID(genreID))),
            URLQueryItem(name: "sort_by", value: "popularity.desc"),
        ])
        // TV lists can be sparse for proxy genres — never let that sink the
        // movie half (and vice versa).
        let movies = (try? await moviePage)?.results.map(\.asMovie) ?? []
        let shows = (try? await tvPage)?.results.map(\.asMovie) ?? []
        if movies.isEmpty && shows.isEmpty { _ = try await moviePage }  // surface the real error
        return (movies + shows).sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
    }

    /// Movies AND shows directed by the person best matching the query,
    /// most popular first. Empty when the query isn't a director.
    func directedMovies(matching query: String) async throws -> [Movie] {
        struct PersonPage: Codable {
            struct Person: Codable {
                let id: Int
                let name: String
                let popularity: Double?
                let knownForDepartment: String?
            }
            let results: [Person]
        }
        let page: PersonPage = try await get(
            "/search/person", query: [URLQueryItem(name: "query", value: query)])
        let q = query.lowercased()
        guard let person = page.results.first(where: {
            ($0.popularity ?? 0) >= 3 &&
            ($0.knownForDepartment == "Directing"
             || $0.name.lowercased().contains(q)
             || Fuzzy.similarity(query: query, candidate: $0.name) >= 0.75)
        }) else { return [] }

        // combined_credits covers shows too — a director query must
        // surface their TV work, not just films.
        struct CreditsPage: Codable {
            struct CrewCredit: Codable {
                let id: Int
                let mediaType: String?
                let title: String?
                let name: String?
                let job: String?
                let posterPath: String?
                let backdropPath: String?
                let genreIds: [Int]?
                let releaseDate: String?
                let firstAirDate: String?
                let overview: String?
                let originalLanguage: String?
                let popularity: Double?
            }
            let crew: [CrewCredit]
        }
        let credits: CreditsPage = try await get("/person/\(person.id)/combined_credits")
        let directed = credits.crew
            .filter { $0.job == "Director" }
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
        var seen = Set<Int>()
        var results: [Movie] = []
        for credit in directed {
            let isTV = credit.mediaType == "tv"
            guard credit.mediaType == "movie" || isTV else { continue }
            guard let title = isTV ? credit.name : credit.title else { continue }
            let id = isTV ? -credit.id : credit.id
            guard seen.insert(id).inserted else { continue }
            let date = isTV ? credit.firstAirDate : credit.releaseDate
            results.append(Movie(
                tmdbID: id, mediaKind: isTV ? "tv" : "movie", title: title,
                releaseYear: date.flatMap { Int($0.prefix(4)) },
                posterPath: credit.posterPath, backdropPath: credit.backdropPath,
                genres: (credit.genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                certification: nil, runtimeMinutes: nil, director: person.name,
                overview: credit.overview, originalLanguage: credit.originalLanguage,
                popularity: credit.popularity, releaseDateFull: date
            ))
        }
        return results
    }

    // MARK: - People

    struct PersonDetails {
        var name: String
        var biography: String?
        var profilePath: String?
        var knownForDepartment: String?
        var birthday: String?

        var photoURL: URL? { TMDBService.imageURL(path: profilePath, size: .profile) }
    }

    func person(id: Int) async throws -> PersonDetails {
        struct DTO: Codable {
            let name: String
            let biography: String?
            let profilePath: String?
            let knownForDepartment: String?
            let birthday: String?
        }
        let dto: DTO = try await get("/person/\(id)")
        return PersonDetails(name: dto.name, biography: dto.biography,
                             profilePath: dto.profilePath,
                             knownForDepartment: dto.knownForDepartment,
                             birthday: dto.birthday)
    }

    /// The most famous person matching a name — the front door to
    /// filmography() for spoken asks ("shows with Neil Patrick Harris").
    func personID(matching query: String) async throws -> Int? {
        struct PersonPage: Codable {
            struct Person: Codable { let id: Int; let popularity: Double? }
            let results: [Person]
        }
        let page: PersonPage = try await get(
            "/search/person", query: [URLQueryItem(name: "query", value: query)])
        return page.results.max(by: { ($0.popularity ?? 0) < ($1.popularity ?? 0) })?.id
    }

    /// Everything they acted in or directed — movies and whole shows
    /// (negative ids), most popular first.
    func filmography(personID: Int) async throws -> [Movie] {
        struct Credit: Codable {
            let id: Int
            let mediaType: String?
            let title: String?
            let name: String?
            let job: String?
            let posterPath: String?
            let backdropPath: String?
            let genreIds: [Int]?
            let releaseDate: String?
            let firstAirDate: String?
            let overview: String?
            let originalLanguage: String?
            let popularity: Double?

            var asMovie: Movie? {
                switch mediaType {
                case "movie":
                    guard let title else { return nil }
                    return Movie(tmdbID: id, mediaKind: "movie", title: title,
                                 releaseYear: releaseDate.flatMap { Int($0.prefix(4)) },
                                 posterPath: posterPath, backdropPath: backdropPath,
                                 genres: (genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                                 certification: nil, runtimeMinutes: nil, director: nil,
                                 overview: overview, originalLanguage: originalLanguage,
                                 popularity: popularity, releaseDateFull: releaseDate)
                case "tv":
                    guard let name else { return nil }
                    return Movie(tmdbID: -id, mediaKind: "tv", title: name,
                                 releaseYear: firstAirDate.flatMap { Int($0.prefix(4)) },
                                 posterPath: posterPath, backdropPath: backdropPath,
                                 genres: (genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                                 certification: nil, runtimeMinutes: nil, director: nil,
                                 overview: overview, originalLanguage: originalLanguage,
                                 popularity: popularity, releaseDateFull: firstAirDate)
                default:
                    return nil
                }
            }
        }
        struct CreditsPage: Codable {
            let cast: [Credit]
            let crew: [Credit]
        }
        let page: CreditsPage = try await get("/person/\(personID)/combined_credits")
        let credits = page.cast + page.crew.filter { $0.job == "Director" }
        var seen = Set<Int>()
        return credits
            .sorted { ($0.popularity ?? 0) > ($1.popularity ?? 0) }
            .compactMap(\.asMovie)
            .filter { seen.insert($0.tmdbID).inserted }
            .prefix(30)
            .map { $0 }
    }

    /// Watch providers for "Where to Watch" (US region by default).
    func watchProviders(for movieID: Int, region: String = "US") async throws -> WatchProviders {
        let response: ProvidersResponse = try await get(Self.mediaPath(movieID, suffix: "/watch/providers"))
        return response.results[region] ?? WatchProviders(link: nil, flatrate: nil, rent: nil, buy: nil)
    }

    /// Provider name → logo URL for every US streaming provider. Powers the
    /// Streaming filter's provider list (CIN-5). Relies on the HTTP cache, so
    /// repeated calls don't re-hit the network.
    func providerLogos(region: String = "US") async -> [String: URL] {
        struct Directory: Decodable { let results: [WatchProviders.Provider] }
        guard let dir: Directory = try? await get(
            "/watch/providers/movie",
            query: [URLQueryItem(name: "watch_region", value: region)]
        ) else { return [:] }
        var map: [String: URL] = [:]
        for provider in dir.results where provider.logoURL != nil {
            map[provider.providerName] = provider.logoURL
        }
        return map
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
        guard var components = URLComponents(string: "https://api.themoviedb.org/3" + path) else {
            throw URLError(.badURL)
        }
        components.queryItems = query + [URLQueryItem(name: "api_key", value: apiKey)]
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
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

/// TV list rows (/discover/tv, /tv/{id}/similar): same shape as movie
/// rows but name/first_air_date, and no media_type to tell them apart —
/// so they get their own page type and negate ids on the way out.
private struct TVListPage: Codable {
    struct Item: Codable {
        let id: Int
        let name: String
        let firstAirDate: String?
        let posterPath: String?
        let backdropPath: String?
        let genreIds: [Int]?
        let overview: String?
        let originalLanguage: String?
        let popularity: Double?

        var asMovie: Movie {
            Movie(tmdbID: -id, mediaKind: "tv", title: name,
                  releaseYear: firstAirDate.flatMap { Int($0.prefix(4)) },
                  posterPath: posterPath, backdropPath: backdropPath,
                  genres: (genreIds ?? []).compactMap { MovieDTO.genreNames[$0] },
                  certification: nil, runtimeMinutes: nil, director: nil,
                  overview: overview, originalLanguage: originalLanguage,
                  popularity: popularity, releaseDateFull: firstAirDate)
        }
    }
    let results: [Item]
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
            originalLanguage: originalLanguage,
            // The calendar's refine pass exists to get EXACT dates — without
            // this the details fetch silently dropped them.
            releaseDateFull: releaseDate
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
