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
    /// TMDB popularity signal; blended into search ranking so big titles
    /// surface even on loose queries.
    var popularity: Double? = nil
    /// Full "yyyy-MM-dd" release date when known (release calendar).
    var releaseDateFull: String? = nil

    var id: Int { tmdbID }

    var posterURL: URL? { TMDBService.imageURL(path: posterPath, size: .poster) }
    var backdropURL: URL? { TMDBService.imageURL(path: backdropPath, size: .backdrop) }

    /// "PG-13 | Sci-Fi, Drama"
    var metadataLine: String {
        let cert = certification ?? "NR"
        let genreText = genres.prefix(2).joined(separator: ", ")
        return genreText.isEmpty ? cert : "\(cert) | \(genreText)"
    }

    /// "2024 · Dir. Denis Villeneuve" — or "TV · 2008 · By Vince Gilligan"
    var bylineText: String {
        var parts: [String] = []
        if mediaKind == "tv" { parts.append("TV") }
        if let releaseYear { parts.append(String(releaseYear)) }
        if let director {
            parts.append(mediaKind == "tv" ? "By \(director)" : "Dir. \(director)")
        }
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
    var memberSince: Date
    var isPrivate: Bool = false
    var streakWeeks: Int = 0
    var lastLoggedWeek: Date?
    var annualGoal: Int?
    var bio: String?
    var instagramHandle: String?
    var tiktokHandle: String?
    var xHandle: String?
    var letterboxdHandle: String?

    /// (label, handle, profile URL) for every linked social, in display order.
    var socialLinks: [(platform: String, handle: String, url: URL)] {
        func link(_ platform: String, _ handle: String?, _ base: String) -> (String, String, URL)? {
            guard let handle, !handle.isEmpty, let url = URL(string: base + handle) else { return nil }
            return (platform, handle, url)
        }
        return [
            link("Instagram", instagramHandle, "https://instagram.com/"),
            link("TikTok", tiktokHandle, "https://tiktok.com/@"),
            link("X", xHandle, "https://x.com/"),
            link("Letterboxd", letterboxdHandle, "https://letterboxd.com/"),
        ].compactMap { $0 }
    }

    var memberSinceText: String {
        "Member since " + memberSince.formatted(.dateTime.month(.wide).year())
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

struct WatchlistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    let createdAt: Date
}

