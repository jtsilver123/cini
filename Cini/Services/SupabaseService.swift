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

    /// Re-send the signup confirmation link to an unconfirmed address.
    func resendConfirmation(email: String) async throws {
        try await client.auth.resend(email: email, type: .signup)
    }

    var currentEmail: String? { client.auth.currentUser?.email }

    /// Sends a confirmation link to the new address; the change applies
    /// once it's tapped.
    func updateEmail(_ email: String) async throws {
        try await client.auth.update(user: UserAttributes(email: email))
    }

    func updatePassword(_ password: String) async throws {
        try await client.auth.update(user: UserAttributes(password: password))
    }

    /// Permanently deletes the auth user; cascades wipe all app data.
    func deleteAccount() async throws {
        try await client.rpc("delete_account").execute()
        try? await client.auth.signOut()
    }

    /// Upload (or replace) the avatar and point the profile at it.
    func uploadAvatar(_ jpegData: Data) async throws -> URL {
        guard let id = currentUserID else { throw URLError(.userAuthenticationRequired) }
        let path = "\(id.uuidString.lowercased()).jpg"
        try await client.storage.from("avatars").upload(
            path,
            data: jpegData,
            options: FileOptions(cacheControl: "3600", contentType: "image/jpeg", upsert: true)
        )
        let publicURL = try client.storage.from("avatars").getPublicURL(path: path)
        // Cache-bust so the new photo shows immediately everywhere.
        let busted = URL(string: publicURL.absoluteString + "?t=\(Int(Date.now.timeIntervalSince1970))") ?? publicURL
        try await updateProfile(ProfileUpdate(avatar_url: busted.absoluteString))
        return busted
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

    // MARK: - Push

    /// Store/refresh this device's APNs token so the send-push edge
    /// function can reach the user. Keyed on token: a device that switches
    /// accounts moves to the new user.
    func registerDeviceToken(_ token: String) async throws {
        guard currentUserID != nil else { return }
        struct Params: Encodable { let p_token: String }
        try await client.rpc("register_device_token", params: Params(p_token: token))
            .execute()
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

    /// A user's own activity stream (RLS-gated like the feed).
    func events(of userID: UUID, limit: Int = 12) async throws -> [FeedEventRow] {
        try await client.from("feed_events")
            .select("*, profiles(username, display_name, avatar_url), movies(*)")
            .eq("user_id", value: userID)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
    }

    func followCount(of userID: UUID, direction: String) async -> Int {
        let response = try? await client.from("follows")
            .select("*", head: true, count: .exact)
            .eq(direction, value: userID)
            .execute()
        return response?.count ?? 0
    }

    /// Cached taste match with another user, if computed.
    func tasteMatch(with userID: UUID) async -> Double? {
        guard let me = currentUserID, me != userID else { return nil }
        struct Row: Codable { let pct: Double }
        let lo = min(me.uuidString, userID.uuidString).lowercased()
        let hi = max(me.uuidString, userID.uuidString).lowercased()
        let rows: [Row]? = try? await client.from("taste_matches")
            .select("pct")
            .eq("user_a", value: lo).eq("user_b", value: hi)
            .execute().value
        return rows?.first?.pct
    }

    func isFollowing(_ userID: UUID) async -> Bool {
        guard let me = currentUserID else { return false }
        let response = try? await client.from("follows")
            .select("*", head: true, count: .exact)
            .eq("follower_id", value: me).eq("following_id", value: userID)
            .execute()
        return (response?.count ?? 0) > 0
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

    // MARK: - Recommendations

    /// Friend-powered recs: movies friends loved (weighted by taste match)
    /// that the user hasn't watched or watchlisted.
    func recsForUser(limit: Int = 30) async throws -> [RecRow] {
        struct Params: Encodable { let p_limit: Int }
        return try await client.rpc("recs_for_user", params: Params(p_limit: limit))
            .execute().value
    }

    // MARK: - Shared watchlists

    func sharedLists() async throws -> [SharedListRow] {
        try await client.from("shared_lists")
            .select()
            .order("created_at", ascending: false)
            .execute().value
    }

    func createSharedList(name: String, emoji: String) async throws -> SharedListRow {
        guard let me = currentUserID else { throw URLError(.userAuthenticationRequired) }
        struct Row: Encodable { let owner_id: UUID; let name: String; let emoji: String }
        return try await client.from("shared_lists")
            .insert(Row(owner_id: me, name: name, emoji: emoji))
            .select().single()
            .execute().value
    }

    func sharedListMovies(listID: UUID) async throws -> [SharedListMovieRow] {
        try await client.from("shared_list_movies")
            .select("*, profiles(username)")
            .eq("list_id", value: listID)
            .order("created_at", ascending: false)
            .execute().value
    }

    func sharedListMembers(listID: UUID) async throws -> [ProfileRow] {
        struct Edge: Codable {
            let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" }
        }
        let edges: [Edge] = try await client.from("shared_list_members")
            .select("user_id")
            .eq("list_id", value: listID)
            .execute().value
        guard !edges.isEmpty else { return [] }
        return try await client.from("profiles")
            .select().in("id", values: edges.map(\.userId))
            .execute().value
    }

    func addToSharedList(listID: UUID, movieID: Int) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let list_id: UUID; let movie_id: Int; let added_by: UUID }
        try await client.from("shared_list_movies")
            .upsert(Row(list_id: listID, movie_id: movieID, added_by: me),
                    onConflict: "list_id,movie_id")
            .execute()
    }

    func inviteToSharedList(listID: UUID, userID: UUID) async throws {
        struct Row: Encodable { let list_id: UUID; let user_id: UUID }
        try await client.from("shared_list_members")
            .upsert(Row(list_id: listID, user_id: userID), onConflict: "list_id,user_id")
            .execute()
    }

    // MARK: - Comments

    func comments(eventID: UUID) async throws -> [CommentRow] {
        try await client.from("comments")
            .select("*, profiles(username, display_name, avatar_url)")
            .eq("event_id", value: eventID)
            .order("created_at")
            .execute().value
    }

    // MARK: - Notifications

    func notifications(limit: Int = 50) async throws -> [NotificationRow] {
        guard let me = currentUserID else { return [] }
        return try await client.from("notifications")
            .select("*, actor:profiles!notifications_actor_id_fkey(username, display_name, avatar_url), movies(title, poster_path)")
            .eq("recipient_id", value: me)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
    }

    func unreadNotificationCount() async -> Int {
        guard let me = currentUserID else { return 0 }
        let response = try? await client.from("notifications")
            .select("*", head: true, count: .exact)
            .eq("recipient_id", value: me)
            .is("read_at", value: nil)
            .execute()
        return response?.count ?? 0
    }

    func markNotificationsRead() async {
        guard let me = currentUserID else { return }
        struct Update: Encodable { let read_at: Date }
        _ = try? await client.from("notifications")
            .update(Update(read_at: .now))
            .eq("recipient_id", value: me)
            .is("read_at", value: nil)
            .execute()
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
    let lastLoggedWeek: String?
    let annualGoal: Int?
    let bio: String?
    let instagramHandle: String?
    let tiktokHandle: String?
    let xHandle: String?
    let letterboxdHandle: String?

    enum CodingKeys: String, CodingKey {
        case id, username, school, bio
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case gradYear = "grad_year"
        case memberSince = "member_since"
        case isPrivate = "is_private"
        case streakWeeks = "streak_weeks"
        case lastLoggedWeek = "last_logged_week"
        case annualGoal = "annual_goal"
        case instagramHandle = "instagram_handle"
        case tiktokHandle = "tiktok_handle"
        case xHandle = "x_handle"
        case letterboxdHandle = "letterboxd_handle"
    }

    var asProfile: Profile {
        Profile(id: id, username: username, displayName: displayName,
                avatarURL: avatarUrl.flatMap(URL.init), school: school, gradYear: gradYear,
                memberSince: memberSince, isPrivate: isPrivate,
                streakWeeks: streakWeeks,
                lastLoggedWeek: lastLoggedWeek.flatMap { ISO8601DateFormatter.dateOnly.date(from: $0) },
                annualGoal: annualGoal,
                bio: bio,
                instagramHandle: instagramHandle, tiktokHandle: tiktokHandle,
                xHandle: xHandle, letterboxdHandle: letterboxdHandle)
    }
}

struct ProfileUpdate: Encodable {
    var username: String?
    var display_name: String?
    var avatar_url: String?
    var school: String?
    var grad_year: Int?
    var annual_goal: Int?
    var is_private: Bool?
    var bio: String?
    var instagram_handle: String?
    var tiktok_handle: String?
    var x_handle: String?
    var letterboxd_handle: String?
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

struct RecRow: Codable, Identifiable, Hashable {
    let movieId: Int
    let recScore: Double
    let friendCount: Int
    let topFriendUsername: String?

    var id: Int { movieId }

    enum CodingKeys: String, CodingKey {
        case movieId = "movie_id"
        case recScore = "rec_score"
        case friendCount = "friend_count"
        case topFriendUsername = "top_friend_username"
    }
}

struct SharedListRow: Codable, Identifiable, Hashable {
    let id: UUID
    let ownerId: UUID
    let name: String
    let emoji: String
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id, name, emoji
        case ownerId = "owner_id"
        case createdAt = "created_at"
    }
}

struct SharedListMovieRow: Codable, Identifiable, Hashable {
    let listId: UUID
    let movieId: Int
    let addedBy: UUID
    let createdAt: Date
    let profiles: AddedByProfile?

    struct AddedByProfile: Codable, Hashable {
        let username: String
    }

    var id: String { "\(listId)-\(movieId)" }

    enum CodingKeys: String, CodingKey {
        case profiles
        case listId = "list_id"
        case movieId = "movie_id"
        case addedBy = "added_by"
        case createdAt = "created_at"
    }
}

struct NotificationRow: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: String
    let actorId: UUID?
    let movieId: Int?
    let readAt: Date?
    let createdAt: Date
    let actor: ActorProfile?
    let movies: MovieStub?

    struct ActorProfile: Codable, Hashable {
        let username: String
        let displayName: String?
        let avatarUrl: String?

        enum CodingKeys: String, CodingKey {
            case username
            case displayName = "display_name"
            case avatarUrl = "avatar_url"
        }
    }

    struct MovieStub: Codable, Hashable {
        let title: String
        let posterPath: String?

        enum CodingKeys: String, CodingKey {
            case title
            case posterPath = "poster_path"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, actor, movies
        case actorId = "actor_id"
        case movieId = "movie_id"
        case readAt = "read_at"
        case createdAt = "created_at"
    }
}

struct CommentRow: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let eventId: UUID
    let body: String
    let createdAt: Date
    let profiles: CommentProfile?

    struct CommentProfile: Codable, Hashable {
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
        case id, body, profiles
        case userId = "user_id"
        case eventId = "event_id"
        case createdAt = "created_at"
    }
}
