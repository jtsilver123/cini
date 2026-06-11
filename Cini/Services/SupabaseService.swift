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

    /// Notification kinds this user has muted (enforced by a DB trigger
    /// at notification creation, silencing both bell and push).
    func mutedNotificationKinds() async -> Set<String> {
        guard let id = currentUserID else { return [] }
        struct Row: Decodable { let muted_notification_kinds: [String] }
        let row: Row? = try? await client.from("profiles")
            .select("muted_notification_kinds")
            .eq("id", value: id)
            .single().execute().value
        return Set(row?.muted_notification_kinds ?? [])
    }

    func setMutedNotificationKinds(_ kinds: Set<String>) async throws {
        guard let id = currentUserID else { return }
        struct Update: Encodable { let muted_notification_kinds: [String] }
        try await client.from("profiles")
            .update(Update(muted_notification_kinds: kinds.sorted()))
            .eq("id", value: id)
            .execute()
    }

    /// Case-insensitive availability check (your own name counts as free).
    func usernameAvailable(_ username: String) async -> Bool {
        struct Params: Encodable { let p_username: String }
        return (try? await client.rpc("username_available", params: Params(p_username: username))
            .execute().value) ?? true   // on network failure, let the DB constraint decide
    }

    func updateProfile(_ update: ProfileUpdate) async throws {
        guard let id = currentUserID else { return }
        try await client.from("profiles").update(update).eq("id", value: id).execute()
    }

    /// Trigram-fuzzy member search (typos in usernames/display names still
    /// match); falls back to plain substring search if the RPC is missing.
    func searchMembers(query: String) async throws -> [ProfileRow] {
        struct Params: Encodable { let p_query: String }
        if let fuzzy: [ProfileRow] = try? await client
            .rpc("search_members", params: Params(p_query: query))
            .execute().value {
            return fuzzy
        }
        return try await client.from("profiles")
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

    // MARK: - Growth: suggestions, contacts, invites

    func suggestedMembers() async throws -> [SuggestedMember] {
        struct Params: Encodable { let p_limit: Int }
        return try await client.rpc("suggested_members", params: Params(p_limit: 25))
            .execute().value
    }

    func membersFromEmails(_ emails: [String]) async throws -> [SuggestedMember] {
        struct Params: Encodable { let p_emails: [String] }
        return try await client.rpc("members_from_emails", params: Params(p_emails: emails))
            .execute().value
    }

    /// New member entered a friend's @username: mutual follow + the
    /// inviter gets a notification.
    @discardableResult
    func redeemInvite(from username: String) async -> Bool {
        struct Params: Encodable { let p_username: String }
        return (try? await client.rpc("redeem_invite_from", params: Params(p_username: username))
            .execute().value) ?? false
    }

    /// Rec Scores ("how much we think you'll like it") for specific
    /// titles — powers the Want to Watch list badges.
    func predictedScores(movieIDs: [Int]) async -> [Int: Double] {
        guard !movieIDs.isEmpty else { return [:] }
        struct Row: Decodable { let movie_id: Int; let predicted: Double }
        struct Params: Encodable { let p_movie_ids: [Int] }
        let rows: [Row] = (try? await client.rpc("predicted_scores",
                                                 params: Params(p_movie_ids: movieIDs))
            .execute().value) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.movie_id, $0.predicted) })
    }

    // MARK: - My details on a movie (notes, performances, labels, watch)

    struct MyMovieDetails {
        var note: String?
        var personalNote: String?
        var labels: [String] = []
        var watchDate: String?
        var watchedWith: [String] = []
        var performances: [(name: String, profilePath: String?)] = []

        var isEmpty: Bool {
            note == nil && personalNote == nil && labels.isEmpty
                && watchDate == nil && watchedWith.isEmpty && performances.isEmpty
        }
    }

    func myMovieDetails(movieID: Int) async -> MyMovieDetails? {
        guard let me = currentUserID else { return nil }

        struct NoteRow: Decodable { let body: String; let is_private: Bool }
        struct PerfRow: Decodable { let person_name: String; let profile_path: String? }
        struct LabelName: Decodable { let name: String }
        struct LabelLink: Decodable { let labels: LabelName? }
        struct RankRow: Decodable {
            let watch_date: String?
            let watched_with: [UUID]?
            let ranking_labels: [LabelLink]?
        }

        async let notesTask: [NoteRow]? = try? client.from("notes")
            .select("body, is_private")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute().value
        async let perfsTask: [PerfRow]? = try? client.from("favorite_performances")
            .select("person_name, profile_path")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute().value
        async let rankTask: RankRow? = try? client.from("rankings")
            .select("watch_date, watched_with, ranking_labels(labels(name))")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .single().execute().value

        var details = MyMovieDetails()
        for row in (await notesTask) ?? [] {
            if row.is_private { details.personalNote = row.body } else { details.note = row.body }
        }
        details.performances = ((await perfsTask) ?? []).map { ($0.person_name, $0.profile_path) }
        if let rank = await rankTask {
            details.watchDate = rank.watch_date
            details.labels = (rank.ranking_labels ?? []).compactMap { $0.labels?.name }
            if let with = rank.watched_with, !with.isEmpty {
                let rows: [ProfileRow]? = try? await client.from("profiles")
                    .select().in("id", values: with).execute().value
                details.watchedWith = (rows ?? []).map(\.username)
            }
        }
        return details.isEmpty ? nil : details
    }

    // MARK: - Direct recs (friend -> friend, optional note)

    func sendDirectRec(to recipient: UUID, movieID: Int, note: String) async -> Bool {
        struct Params: Encodable {
            let p_recipient: UUID
            let p_movie_id: Int
            let p_note: String?
        }
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? await client.rpc(
            "send_direct_rec",
            params: Params(p_recipient: recipient, p_movie_id: movieID,
                           p_note: trimmed.isEmpty ? nil : trimmed)
        ).execute().value) ?? false
    }

    func directRecs() async throws -> [DirectRecRow] {
        guard let me = currentUserID else { return [] }
        return try await client.from("direct_recs")
            .select("id, sender_id, movie_id, note, created_at, profiles!direct_recs_sender_id_fkey(username, display_name, avatar_url), movies(*)")
            .eq("recipient_id", value: me)
            .order("created_at", ascending: false)
            .limit(20)
            .execute().value
    }

    func dismissDirectRec(id: UUID) async {
        _ = try? await client.from("direct_recs").delete().eq("id", value: id).execute()
    }

    // MARK: - Desktop import transfer

    /// Mint a short-lived transfer code; the user enters it at the web
    /// import page and the export lands in our private bucket.
    func createImportCode() async throws -> String {
        guard let me = currentUserID else { throw URLError(.userAuthenticationRequired) }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let code = String((0..<6).map { _ in alphabet.randomElement()! })
        struct Row: Encodable { let code: String; let user_id: UUID }
        try await client.from("pending_imports")
            .insert(Row(code: code, user_id: me))
            .execute()
        return code
    }

    /// Storage path of the uploaded export once the computer side is done.
    func importUploadPath(code: String) async -> String? {
        struct Row: Decodable { let status: String; let path: String? }
        let row: Row? = try? await client.from("pending_imports")
            .select("status, path")
            .eq("code", value: code)
            .single().execute().value
        return row?.status == "ready" ? row?.path : nil
    }

    func downloadImport(path: String) async throws -> Data {
        try await client.storage.from("imports").download(path: path)
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

    /// Replace this user's labels on a ranked movie.
    func setRankingLabels(movieID: Int, labels: [String]) async throws {
        struct Params: Encodable { let p_movie_id: Int; let p_labels: [String] }
        try await client.rpc("set_ranking_labels",
                             params: Params(p_movie_id: movieID, p_labels: labels))
            .execute()
    }

    /// The community's most-used labels for a movie (anonymous aggregate).
    func movieTopLabels(movieID: Int) async throws -> [String] {
        struct Row: Decodable { let name: String }
        struct Params: Encodable { let p_movie_id: Int }
        let rows: [Row] = try await client.rpc("movie_top_labels",
                                               params: Params(p_movie_id: movieID))
            .execute().value
        return rows.map(\.name)
    }

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

    /// How often each friend has been tagged in "watched with" across all
    /// of the user's rankings — ranks the picker so frequent movie
    /// companions surface first.
    func watchedWithCounts() async -> [UUID: Int] {
        guard let me = currentUserID else { return [:] }
        struct Row: Decodable { let watched_with: [UUID]? }
        let rows: [Row] = (try? await client.from("rankings")
            .select("watched_with")
            .eq("user_id", value: me)
            .execute().value) ?? []
        var counts: [UUID: Int] = [:]
        for row in rows {
            for id in row.watched_with ?? [] { counts[id, default: 0] += 1 }
        }
        return counts
    }

    /// Members following `userID` (.followers) or whom they follow
    /// (.following) — newest edge first.
    enum FollowDirection { case followers, following }

    func followMembers(of userID: UUID, direction: FollowDirection) async throws -> [ProfileRow] {
        struct Edge: Codable {
            let followerId: UUID
            let followingId: UUID
            enum CodingKeys: String, CodingKey {
                case followerId = "follower_id"
                case followingId = "following_id"
            }
        }
        let matchColumn = direction == .followers ? "following_id" : "follower_id"
        let edges: [Edge] = try await client.from("follows")
            .select("follower_id, following_id")
            .eq(matchColumn, value: userID)
            .order("created_at", ascending: false)
            .execute().value
        let ids = edges.map { direction == .followers ? $0.followerId : $0.followingId }
        guard !ids.isEmpty else { return [] }
        let rows: [ProfileRow] = try await client.from("profiles")
            .select()
            .in("id", values: ids)
            .execute().value
        // restore edge order (newest follow first)
        let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
        return rows.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
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

    /// Which of these feed events the current user already liked — one
    /// query for the whole visible feed, so hearts survive a refresh.
    func myLikedEventIDs(_ eventIDs: [UUID]) async -> Set<UUID> {
        guard let me = currentUserID, !eventIDs.isEmpty else { return [] }
        struct Row: Decodable { let event_id: UUID }
        let rows: [Row] = (try? await client.from("likes")
            .select("event_id")
            .eq("user_id", value: me)
            .in("event_id", values: eventIDs)
            .execute().value) ?? []
        return Set(rows.map(\.event_id))
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

    func leaderboard(metric: String, genre: String?) async throws -> [LeaderboardRow] {
        struct Params: Encodable {
            let p_metric: String
            let p_school: String?   // RPC signature requires it; always nil
            let p_genre: String?
        }
        return try await client.rpc(
            "leaderboard",
            params: Params(p_metric: metric, p_school: nil, p_genre: genre)
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
        case id, username, bio
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
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
                avatarURL: avatarUrl.flatMap(URL.init),
                memberSince: memberSince, isPrivate: isPrivate,
                streakWeeks: streakWeeks,
                lastLoggedWeek: lastLoggedWeek.flatMap { ISO8601DateFormatter.dateOnly.date(from: $0) },
                annualGoal: annualGoal,
                bio: bio,
                instagramHandle: instagramHandle, tiktokHandle: tiktokHandle,
                xHandle: xHandle, letterboxdHandle: letterboxdHandle)
    }
}

struct DirectRecRow: Decodable, Identifiable, Hashable {
    let id: UUID
    let senderId: UUID
    let movieId: Int
    let note: String?
    let createdAt: Date
    let profiles: FeedEventRow.EmbeddedProfile?
    let movies: MovieRow?

    enum CodingKeys: String, CodingKey {
        case id, note, profiles, movies
        case senderId = "sender_id"
        case movieId = "movie_id"
        case createdAt = "created_at"
    }
}

/// Row from suggested_members / members_from_emails.
struct SuggestedMember: Decodable, Identifiable, Hashable {
    let id: UUID
    let username: String
    let displayName: String
    let avatarUrl: String?
    let matchPct: Double?
    let watched: Int

    enum CodingKeys: String, CodingKey {
        case id, username, watched
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case matchPct = "match_pct"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        username = try c.decode(String.self, forKey: .username)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        avatarUrl = try? c.decode(String.self, forKey: .avatarUrl)
        matchPct = try? c.decode(Double.self, forKey: .matchPct)
        watched = (try? c.decode(Int.self, forKey: .watched)) ?? 0
    }
}

struct ProfileUpdate: Encodable {
    var username: String?
    var display_name: String?
    var avatar_url: String?
    var annual_goal: Int?
    var is_private: Bool?
    var bio: String?
    var home_zip: String?
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
    let payload: Payload?
    let profiles: EmbeddedProfile?
    let movies: MovieRow?

    struct Payload: Codable, Hashable {
        let score: Double?
    }

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
        case id, profiles, movies, payload
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
    let value: Int
    let matchPct: Double?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, value
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
