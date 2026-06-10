import Foundation
import Supabase
import RankingEngine

/// Thin async wrapper over supabase-swift: auth, table reads, and the
/// transactional RPCs from supabase/migrations/0003_functions.sql.
final class SupabaseService {
    static let shared = SupabaseService()

    let client: SupabaseClient

    init() {
        client = SupabaseClient(
            supabaseURL: AppConfig.supabaseURL,
            supabaseKey: AppConfig.supabaseAnonKey
        )
    }

    var currentUserID: UUID? {
        client.auth.currentUser?.id
    }

    // MARK: - Auth

    func signInWithApple(idToken: String, nonce: String) async throws {
        try await client.auth.signInWithIdToken(
            credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
        )
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String, username: String) async throws {
        try await client.auth.signUp(
            email: email,
            password: password,
            data: ["username": .string(username)]
        )
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    // MARK: - Profiles

    func profile(id: UUID) async throws -> ProfileRow {
        try await client.from("profiles").select().eq("id", value: id).single().execute().value
    }

    func updateProfile(_ update: ProfileUpdate) async throws {
        guard let id = currentUserID else { return }
        try await client.from("profiles").update(update).eq("id", value: id).execute()
    }

    func searchMembers(query: String) async throws -> [ProfileRow] {
        try await client.from("profiles")
            .select()
            .ilike("username", pattern: "%\(query)%")
            .limit(25)
            .execute().value
    }

    // MARK: - Movies cache

    func cacheMovie(_ movie: Movie) async throws {
        try await client.rpc("cache_movie", params: CacheMovieParams(movie: movie)).execute()
    }

    func movies(ids: [Int]) async throws -> [MovieRow] {
        guard !ids.isEmpty else { return [] }
        return try await client.from("movies").select().in("tmdb_id", values: ids).execute().value
    }

    // MARK: - Rankings (atomic via RPC)

    func rankInsert(movieID: Int, bucket: Sentiment, position: Int, watchDate: Date? = nil) async throws -> RankingRow {
        struct Params: Encodable {
            let p_movie_id: Int
            let p_bucket: String
            let p_position: Int
            let p_watch_date: String?
        }
        let dateString = watchDate.map { ISO8601DateFormatter.dateOnly.string(from: $0) }
        return try await client.rpc(
            "rank_insert",
            params: Params(p_movie_id: movieID, p_bucket: bucket.rawValue,
                           p_position: position, p_watch_date: dateString)
        ).single().execute().value
    }

    func rankRemove(movieID: Int) async throws {
        struct Params: Encodable { let p_movie_id: Int }
        try await client.rpc("rank_remove", params: Params(p_movie_id: movieID)).execute()
    }

    func rankings(userID: UUID) async throws -> [RankingRow] {
        try await client.from("rankings")
            .select()
            .eq("user_id", value: userID)
            .order("bucket").order("position")
            .execute().value
    }

    // MARK: - Watchlist

    @discardableResult
    func watchlistToggle(movieID: Int) async throws -> Bool {
        struct Params: Encodable { let p_movie_id: Int }
        return try await client.rpc("watchlist_toggle", params: Params(p_movie_id: movieID))
            .execute().value
    }

    func watchlist(userID: UUID) async throws -> [WatchlistRow] {
        try await client.from("watchlist")
            .select()
            .eq("user_id", value: userID)
            .order("created_at", ascending: false)
            .execute().value
    }

    // MARK: - Notes, performances, labels

    func upsertNote(movieID: Int, body: String, isPrivate: Bool) async throws {
        guard let userID = currentUserID else { return }
        struct Row: Encodable {
            let user_id: UUID
            let movie_id: Int
            let body: String
            let is_private: Bool
        }
        try await client.from("notes")
            .upsert(Row(user_id: userID, movie_id: movieID, body: body, is_private: isPrivate),
                    onConflict: "user_id,movie_id,is_private")
            .execute()
    }

    func addPerformance(movieID: Int, cast: CastMember) async throws {
        guard let userID = currentUserID else { return }
        struct Row: Encodable {
            let user_id: UUID
            let movie_id: Int
            let tmdb_person_id: Int
            let person_name: String
            let profile_path: String?
            let character_name: String?
        }
        try await client.from("favorite_performances")
            .upsert(Row(user_id: userID, movie_id: movieID, tmdb_person_id: cast.id,
                        person_name: cast.name, profile_path: cast.profilePath,
                        character_name: cast.character),
                    onConflict: "user_id,movie_id,tmdb_person_id")
            .execute()
    }

    func topPerformances(movieID: Int) async throws -> [PerformanceCount] {
        let rows: [PerformanceCount] = try await client.from("favorite_performances")
            .select("tmdb_person_id, person_name, profile_path")
            .eq("movie_id", value: movieID)
            .execute().value
        // Tally recommendations per person.
        var counts: [Int: PerformanceCount] = [:]
        for row in rows {
            if var existing = counts[row.tmdbPersonId] {
                existing.count += 1
                counts[row.tmdbPersonId] = existing
            } else {
                counts[row.tmdbPersonId] = row
            }
        }
        return counts.values.sorted { $0.count > $1.count }
    }

    // MARK: - Ranking enrichment

    func updateRanking(movieID: Int, watchedWith: [UUID], watchDate: Date?) async throws {
        guard let me = currentUserID else { return }
        struct Update: Encodable {
            let watched_with: [UUID]
            let watch_date: String?
        }
        let dateString = watchDate.map { ISO8601DateFormatter.dateOnly.string(from: $0) }
        try await client.from("rankings")
            .update(Update(watched_with: watchedWith, watch_date: dateString))
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute()
    }

    /// Stealth mode: pull the 'ranked' event for this movie off the feed.
    func hideRankEvent(movieID: Int) async throws {
        guard let me = currentUserID else { return }
        try await client.from("feed_events")
            .delete()
            .eq("user_id", value: me)
            .eq("movie_id", value: movieID)
            .eq("event_type", value: "ranked")
            .execute()
    }

    // MARK: - Social

    /// Profiles the current user follows (for "Who did you watch with?").
    func following() async throws -> [ProfileRow] {
        guard let me = currentUserID else { return [] }
        struct Edge: Codable {
            let followingId: UUID
            enum CodingKeys: String, CodingKey { case followingId = "following_id" }
        }
        let edges: [Edge] = try await client.from("follows")
            .select("following_id")
            .eq("follower_id", value: me)
            .execute().value
        guard !edges.isEmpty else { return [] }
        return try await client.from("profiles")
            .select()
            .in("id", values: edges.map(\.followingId))
            .execute().value
    }

    func follow(_ userID: UUID) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let follower_id: UUID; let following_id: UUID }
        try await client.from("follows")
            .insert(Row(follower_id: me, following_id: userID)).execute()
    }

    func unfollow(_ userID: UUID) async throws {
        guard let me = currentUserID else { return }
        try await client.from("follows")
            .delete()
            .eq("follower_id", value: me).eq("following_id", value: userID)
            .execute()
    }

    func feed(limit: Int = 50) async throws -> [FeedEventRow] {
        // RLS limits rows to people the viewer can see; order newest first.
        try await client.from("feed_events")
            .select("*, profiles(username, display_name, avatar_url), movies(*)")
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
    }

    func toggleLike(eventID: UUID) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let user_id: UUID; let event_id: UUID }
        let existing: [Row2] = try await client.from("likes")
            .select("event_id")
            .eq("user_id", value: me).eq("event_id", value: eventID)
            .execute().value
        if existing.isEmpty {
            try await client.from("likes").insert(Row(user_id: me, event_id: eventID)).execute()
        } else {
            try await client.from("likes").delete()
                .eq("user_id", value: me).eq("event_id", value: eventID).execute()
        }
    }

    func comment(eventID: UUID, body: String) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let user_id: UUID; let event_id: UUID; let body: String }
        try await client.from("comments").insert(Row(user_id: me, event_id: eventID, body: body)).execute()
    }

    // MARK: - Detail page aggregates

    func communityScore(movieID: Int) async throws -> CommunityScore? {
        let rows: [CommunityScore] = try await client.from("movie_community_scores")
            .select().eq("movie_id", value: movieID).execute().value
        return rows.first
    }

    func friendScores(movieID: Int) async throws -> [FriendScoreRow] {
        struct Params: Encodable { let p_movie_id: Int }
        return try await client.rpc("movie_friend_scores", params: Params(p_movie_id: movieID))
            .execute().value
    }

    func scoreHistogram(movieID: Int) async throws -> [HistogramBin] {
        struct Params: Encodable { let p_movie_id: Int }
        return try await client.rpc("movie_score_histogram", params: Params(p_movie_id: movieID))
            .execute().value
    }

    // MARK: - Leaderboard & rank

    func leaderboard(metric: String, school: String?, genre: String?) async throws -> [LeaderboardRow] {
        struct Params: Encodable {
            let p_metric: String
            let p_school: String?
            let p_genre: String?
        }
        return try await client.rpc(
            "leaderboard",
            params: Params(p_metric: metric, p_school: school, p_genre: genre)
        ).execute().value
    }

    func globalRank(userID: UUID) async throws -> Int {
        struct Params: Encodable { let p_user: UUID }
        return try await client.rpc("global_rank", params: Params(p_user: userID)).execute().value
    }
}

extension ISO8601DateFormatter {
    static let dateOnly: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}

// MARK: - Row types (snake_case mirrors of the schema)

struct ProfileRow: Codable, Identifiable, Hashable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarUrl: String?
    let school: String?
    let gradYear: Int?
    let memberSince: Date
    let isPrivate: Bool
    let streakWeeks: Int
    let annualGoal: Int?

    enum CodingKeys: String, CodingKey {
        case id, username, school
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case gradYear = "grad_year"
        case memberSince = "member_since"
        case isPrivate = "is_private"
        case streakWeeks = "streak_weeks"
        case annualGoal = "annual_goal"
    }

    var asProfile: Profile {
        Profile(id: id, username: username, displayName: displayName,
                avatarURL: avatarUrl.flatMap(URL.init), school: school, gradYear: gradYear,
                memberSince: memberSince, isPrivate: isPrivate,
                streakWeeks: streakWeeks, annualGoal: annualGoal)
    }
}

struct ProfileUpdate: Encodable {
    var display_name: String?
    var avatar_url: String?
    var school: String?
    var grad_year: Int?
    var annual_goal: Int?
    var is_private: Bool?
}

struct MovieRow: Codable, Hashable {
    let tmdbId: Int
    let mediaKind: String
    let title: String
    let releaseYear: Int?
    let posterPath: String?
    let backdropPath: String?
    let genres: [String]
    let certification: String?
    let runtimeMinutes: Int?
    let director: String?
    let overview: String?

    enum CodingKeys: String, CodingKey {
        case title, genres, certification, director, overview
        case tmdbId = "tmdb_id"
        case mediaKind = "media_kind"
        case releaseYear = "release_year"
        case posterPath = "poster_path"
        case backdropPath = "backdrop_path"
        case runtimeMinutes = "runtime_minutes"
    }

    var asMovie: Movie {
        Movie(tmdbID: tmdbId, mediaKind: mediaKind, title: title, releaseYear: releaseYear,
              posterPath: posterPath, backdropPath: backdropPath, genres: genres,
              certification: certification, runtimeMinutes: runtimeMinutes,
              director: director, overview: overview)
    }
}

private struct CacheMovieParams: Encodable {
    let p_tmdb_id: Int
    let p_media_kind: String
    let p_title: String
    let p_release_year: Int?
    let p_poster_path: String?
    let p_backdrop_path: String?
    let p_genres: [String]
    let p_certification: String?
    let p_runtime_minutes: Int?
    let p_director: String?
    let p_overview: String?

    init(movie: Movie) {
        p_tmdb_id = movie.tmdbID
        p_media_kind = movie.mediaKind
        p_title = movie.title
        p_release_year = movie.releaseYear
        p_poster_path = movie.posterPath
        p_backdrop_path = movie.backdropPath
        p_genres = movie.genres
        p_certification = movie.certification
        p_runtime_minutes = movie.runtimeMinutes
        p_director = movie.director
        p_overview = movie.overview
    }
}

struct RankingRow: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let movieId: Int
    let bucket: String
    let position: Int
    let score: Double
    let watchDate: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, bucket, position, score
        case userId = "user_id"
        case movieId = "movie_id"
        case watchDate = "watch_date"
        case createdAt = "created_at"
    }
}

struct WatchlistRow: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let movieId: Int
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case movieId = "movie_id"
        case createdAt = "created_at"
    }
}

struct FeedEventRow: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let eventType: String
    let movieId: Int?
    let createdAt: Date
    let profiles: EmbeddedProfile?
    let movies: MovieRow?

    struct EmbeddedProfile: Codable, Hashable {
        let username: String
        let displayName: String?
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, profiles, movies
        case userId = "user_id"
        case eventType = "event_type"
        case movieId = "movie_id"
        case createdAt = "created_at"
    }
}

struct CommunityScore: Codable, Hashable {
    let movieId: Int
    let avgScore: Double
    let ratingCount: Int

    enum CodingKeys: String, CodingKey {
        case movieId = "movie_id"
        case avgScore = "avg_score"
        case ratingCount = "rating_count"
    }
}

struct FriendScoreRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let score: Double
    let note: String?
    let rankedAt: Date

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, score, note
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case rankedAt = "ranked_at"
    }
}

struct HistogramBin: Codable, Hashable {
    let bucketFloor: Int
    let n: Int

    enum CodingKeys: String, CodingKey {
        case bucketFloor = "bucket_floor"
        case n
    }
}

struct LeaderboardRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let avatarUrl: String?
    let school: String?
    let value: Int
    let matchPct: Double?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, school, value
        case userId = "user_id"
        case avatarUrl = "avatar_url"
        case matchPct = "match_pct"
    }
}

struct PerformanceCount: Codable, Hashable {
    let tmdbPersonId: Int
    let personName: String
    let profilePath: String?
    var count: Int = 1

    enum CodingKeys: String, CodingKey {
        case tmdbPersonId = "tmdb_person_id"
        case personName = "person_name"
        case profilePath = "profile_path"
    }

    var photoURL: URL? { TMDBService.imageURL(path: profilePath, size: .profile) }
}

private struct Row2: Codable {
    let eventId: UUID
    enum CodingKeys: String, CodingKey { case eventId = "event_id" }
}
