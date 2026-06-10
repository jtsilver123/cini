import Foundation
import RankingEngine

// MARK: - Category (Beli's Restaurants/Bars/Bakeries → media kinds)

enum MediaCategory: String, CaseIterable, Codable, Identifiable {
    case movies, tvShows, documentaries, anime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .tvShows: return "TV Shows"
        case .documentaries: return "Documentaries"
        case .anime: return "Anime"
        }
    }

    var icon: String {
        switch self {
        case .movies: return "film"
        case .tvShows: return "tv"
        case .documentaries: return "video"
        case .anime: return "sparkles.tv"
        }
    }

    var mediaKind: String {
        switch self {
        case .movies: return "movie"
        case .tvShows: return "tv"
        case .documentaries: return "documentary"
        case .anime: return "anime"
        }
    }
}

// MARK: - Movie (cached TMDB metadata; v1 ranks TV as whole seasons only)

struct Movie: Identifiable, Codable, Hashable {
    let tmdbID: Int
    var mediaKind: String
    var title: String
    var releaseYear: Int?
    var posterPath: String?
    var backdropPath: String?
    var genres: [String]
    var certification: String?
    var runtimeMinutes: Int?
    var director: String?
    var overview: String?
    /// ISO 639-1 original language code from TMDB (e.g. "en", "ko").
    var originalLanguage: String?
    /// "On Netflix, Max" — filled from the TMDB watch-provider endpoint.
    var streamingOn: [String] = []

    var id: Int { tmdbID }

    var posterURL: URL? { TMDBService.imageURL(path: posterPath, size: .poster) }
    var backdropURL: URL? { TMDBService.imageURL(path: backdropPath, size: .backdrop) }

    /// "PG-13 | Sci-Fi, Drama"
    var metadataLine: String {
        let cert = certification ?? "NR"
        let genreText = genres.prefix(2).joined(separator: ", ")
        return genreText.isEmpty ? cert : "\(cert) | \(genreText)"
    }

    /// "2024 · Dir. Denis Villeneuve"
    var bylineText: String {
        var parts: [String] = []
        if let releaseYear { parts.append(String(releaseYear)) }
        if let director { parts.append("Dir. \(director)") }
        return parts.joined(separator: " · ")
    }

    var runtimeText: String? {
        guard let runtimeMinutes else { return nil }
        return "\(runtimeMinutes / 60)h \(runtimeMinutes % 60)m"
    }

    var availabilityText: String? {
        streamingOn.isEmpty ? nil : "On " + streamingOn.prefix(2).joined(separator: ", ")
    }

    /// "Korean", "French" — localized display name for the language filter.
    var languageName: String? {
        originalLanguage.flatMap { Locale.current.localizedString(forLanguageCode: $0) }
    }
}

// MARK: - Profile

struct Profile: Identifiable, Codable, Hashable {
    let id: UUID
    var username: String
    var displayName: String
    var avatarURL: URL?
    var school: String?
    var gradYear: Int?
    var memberSince: Date
    var isPrivate: Bool = false
    var streakWeeks: Int = 0
    var lastLoggedWeek: Date?
    var annualGoal: Int?

    var memberSinceText: String {
        "Member since " + memberSince.formatted(.dateTime.month(.wide).year())
    }

    var schoolLine: String? {
        guard let school else { return nil }
        if let gradYear { return "\(school) '\(String(gradYear).suffix(2))" }
        return school
    }

    /// True when there's a live streak that hasn't been fed this week.
    var streakAtRisk: Bool {
        guard streakWeeks > 0 else { return false }
        guard let lastLoggedWeek else { return true }
        let thisWeek = Calendar(identifier: .iso8601)
            .dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return lastLoggedWeek < thisWeek
    }

    var hasLoggedThisWeek: Bool {
        guard let lastLoggedWeek else { return false }
        let thisWeek = Calendar(identifier: .iso8601)
            .dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        return lastLoggedWeek >= thisWeek
    }
}

// MARK: - Ranking / Watchlist

struct Ranking: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    var bucket: Sentiment
    var position: Int
    var score: Double
    var watchDate: Date?
    var watchedWith: [UUID]
    var createdAt: Date
}

struct WatchlistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    let createdAt: Date
}

// MARK: - Notes & performances

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    var body: String
    var isPrivate: Bool
    var createdAt: Date
}

struct FavoritePerformance: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    let tmdbPersonID: Int
    let personName: String
    let profilePath: String?
    let characterName: String?

    var photoURL: URL? { TMDBService.imageURL(path: profilePath, size: .profile) }
}

struct MovieLabel: Identifiable, Codable, Hashable {
    let id: UUID
    let ownerID: UUID?
    let name: String
}

// MARK: - Social

struct FeedEvent: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case ranked, watchlisted, noted
        case challengeMilestone = "challenge_milestone"
        case streakMilestone = "streak_milestone"
        case askedForRecs = "asked_for_recs"
    }

    let id: UUID
    let userID: UUID
    let kind: Kind
    let movieID: Int?
    let payload: [String: AnyCodableValue]
    let createdAt: Date

    var score: Double? { payload["score"]?.doubleValue }

    var likeCount: Int = 0
    var commentCount: Int = 0
    var likedByMe: Bool = false
}

struct FeedComment: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let eventID: UUID
    let body: String
    let createdAt: Date
}

struct FriendScore: Identifiable, Codable, Hashable {
    let userID: UUID
    let username: String
    let displayName: String
    let avatarURL: URL?
    let score: Double
    let note: String?
    let rankedAt: Date

    var id: UUID { userID }
}

struct LeaderboardEntry: Identifiable, Codable, Hashable {
    let userID: UUID
    let username: String
    let avatarURL: URL?
    let school: String?
    let value: Int
    let matchPct: Double?

    var id: UUID { userID }
}

struct AppNotification: Identifiable, Codable, Hashable {
    enum Kind: String, Codable {
        case like, comment, newFollower = "new_follower"
        case friendRankedWatchlistMovie = "friend_ranked_watchlist_movie"
    }

    let id: UUID
    let actorID: UUID?
    let kind: Kind
    let movieID: Int?
    var readAt: Date?
    let createdAt: Date
}

// MARK: - JSON payload helper

enum AnyCodableValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    var doubleValue: Double? {
        if case .number(let d) = self { return d }
        return nil
    }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) { self = .number(d) }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else { self = .null }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .number(let d): try container.encode(d)
        case .bool(let b): try container.encode(b)
        case .null: try container.encodeNil()
        }
    }
}
