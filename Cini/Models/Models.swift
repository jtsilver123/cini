import Foundation
import RankingEngine

// MARK: - Category (Beli's Restaurants/Bars/Bakeries → media kinds)

/// Movies and TV shows are the ONLY two content types. Documentaries,
/// anime, and friends are genres — searchable and filterable, never
/// categories of their own.
enum MediaCategory: String, CaseIterable, Codable, Identifiable {
    case movies, tvShows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .movies: return "Movies"
        case .tvShows: return "TV Shows"
        }
    }

    var icon: String {
        switch self {
        case .movies: return "film"
        case .tvShows: return "tv"
        }
    }

    var mediaKind: String {
        switch self {
        case .movies: return "movie"
        case .tvShows: return "tv"
        }
    }

    func matches(_ movie: Movie) -> Bool {
        switch self {
        case .movies: return movie.mediaKind != "tv"
        case .tvShows: return movie.mediaKind == "tv"
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
        var parts = [certification ?? "NR"]
        if mediaKind == "tv" { parts.append("TV Series") }
        let genreText = genres.prefix(2).joined(separator: ", ")
        if !genreText.isEmpty { parts.append(genreText) }
        return parts.joined(separator: " | ")
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
        // Sub-hour runtimes (TV episodes, shorts) read "45m", not "0h 45m".
        if runtimeMinutes < 60 { return "\(runtimeMinutes)m" }
        return "\(runtimeMinutes / 60)h \(runtimeMinutes % 60)m"
    }

    /// You can only rank what's out. Precise when TMDB gave a full date;
    /// otherwise only a future *year* blocks it (a release this year with no
    /// exact date is allowed rather than wrongly blocked).
    var isReleased: Bool {
        if let releaseDateFull, releaseDateFull.count == 10 {
            return releaseDateFull <= Movie.todayISO
        }
        if let releaseYear { return releaseYear <= Movie.currentYear }
        return true
    }

    /// Short "releases …" line for the not-yet-out state.
    var releaseWhenText: String {
        if let releaseDateFull, releaseDateFull.count == 10 {
            let f = DateFormatter()
            f.calendar = Calendar(identifier: .gregorian)
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd"
            if let date = f.date(from: releaseDateFull) {
                return "Releases " + date.formatted(.dateTime.month(.abbreviated).day().year())
            }
        }
        if let releaseYear { return "Releases \(releaseYear)" }
        return "Not out yet"
    }

    private static let currentYear = Calendar(identifier: .gregorian).component(.year, from: .now)
    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    /// Cached per day — isReleased runs hundreds of times per month-grid
    /// render, and a fresh DateFormatter per call was measurable.
    private static var cachedTodayISO = (day: "", value: "")
    private static var todayISO: String {
        // Cheap staleness check: rebuild only when the day changes.
        let now = Date()
        let day = String(describing: Calendar(identifier: .gregorian)
            .ordinality(of: .day, in: .era, for: now) ?? 0)
        if cachedTodayISO.day != day {
            cachedTodayISO = (day, todayFormatter.string(from: now))
        }
        return cachedTodayISO.value
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
    /// Date-only "YYYY-MM-DD" anchor of the week the user last ranked, stamped
    /// by rank_insert in the user's local timezone. Kept as a String (date-only
    /// columns can't decode as Date) and compared lexicographically.
    var lastLoggedWeek: String?
    var annualGoal: Int?
    var bio: String?
    var instagramHandle: String?
    var tiktokHandle: String?
    var xHandle: String?
    var letterboxdHandle: String?
    /// The user's college, picked from a canonical list so classmates share the
    /// exact same string — powers campus leaderboards and "what your school is
    /// watching." Optional; set whenever from the profile.
    var school: String?

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

    /// "YYYY-MM-DD" Monday of the current week in the device's LOCAL timezone —
    /// the exact anchor rank_insert stamps (it computes the week in the device
    /// zone too), so the two always agree and match the user's lived week.
    /// Anchoring in UTC made a Sunday-evening rank (which is already the next
    /// UTC week for anyone behind UTC) look at-risk right after ranking.
    static var currentWeekStart: String {
        let cal = Calendar(identifier: .iso8601)   // device-local timezone
        let start = cal.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = cal.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: start)
    }

    /// True when there's a live streak that hasn't been fed this week. Compares
    /// date-only strings lexicographically (correct for YYYY-MM-DD), avoiding
    /// any instant/timezone skew between the stamped date and "now".
    var streakAtRisk: Bool {
        guard streakWeeks > 0 else { return false }
        guard let lastLoggedWeek else { return true }
        return lastLoggedWeek < Profile.currentWeekStart
    }

    var hasLoggedThisWeek: Bool {
        guard let lastLoggedWeek else { return false }
        return lastLoggedWeek >= Profile.currentWeekStart
    }
}

// MARK: - Ranking / Watchlist

struct WatchlistItem: Identifiable, Codable, Hashable {
    let id: UUID
    let userID: UUID
    let movieID: Int
    let createdAt: Date
    /// The "why I saved this" note from the save popup.
    var note: String?
    /// Optional "watch by" goal date (ISO yyyy-MM-dd).
    var watchBy: String?
}

