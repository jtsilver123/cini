import Foundation
import OSLog
import Supabase
import RankingEngine

/// Thin async wrapper over supabase-swift: auth, table reads, and the
/// transactional RPCs from supabase/migrations/0003_functions.sql.
final class SupabaseService {
    static let shared = SupabaseService()

    /// Swallowed errors still get logged — silent contract drift is how
    /// the feed, the recs inbox, and invites all broke invisibly. Anything
    /// that degrades gracefully must shout here first.
    static func logSwallowed(_ context: String, _ error: Error) {
        Logger(subsystem: "app.cini.ios", category: "supabase")
            .error("\(context, privacy: .public): \(String(describing: error), privacy: .public)")
        #if DEBUG
        print("⚠️ supabase \(context): \(error)")
        #endif
    }

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

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    /// Log in with a phone number + password. The phone→account lookup runs
    /// in the `phone-login` edge function (service role), which returns a
    /// session we adopt — no OTP, and the client never sees phone→email.
    func signInWithPhone(phone: String, password: String) async throws {
        struct Body: Encodable { let phone: String; let password: String }
        try await loginViaFunction(Body(phone: phone, password: password))
    }

    /// Log in with a username + password. Same `phone-login` edge function and
    /// guarantees as phone login: the username→account lookup runs server-side
    /// (service role), so the client never sees username→email.
    func signInWithUsername(username: String, password: String) async throws {
        struct Body: Encodable { let username: String; let password: String }
        try await loginViaFunction(Body(username: username, password: password))
    }

    /// Session tokens returned by the login edge function. Declared at type
    /// scope — Swift forbids a local type inside a generic function.
    private struct LoginTokens: Decodable { let access_token: String; let refresh_token: String }

    /// Shared tail for the edge-function logins: invoke, then adopt the session.
    private func loginViaFunction<B: Encodable>(_ body: B) async throws {
        let tokens: LoginTokens = try await client.functions.invoke(
            "phone-login", options: FunctionInvokeOptions(body: body))
        try await client.auth.setSession(accessToken: tokens.access_token,
                                         refreshToken: tokens.refresh_token)
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

    /// Remove this device's push token (RLS: delete-own only).
    func unregisterDeviceToken(_ token: String) async {
        do {
            try await client.from("device_tokens").delete()
                .eq("token", value: token).execute()
        } catch {
            Self.logSwallowed("unregister_device_token", error)
        }
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
        do {
            return try await client.rpc("username_available", params: Params(p_username: username))
                .execute().value
        } catch {
            // On failure, let the DB unique constraint decide at save time.
            Self.logSwallowed("username_available", error)
            return true
        }
    }

    func updateProfile(_ update: ProfileUpdate) async throws {
        guard let id = currentUserID else { return }
        try await client.from("profiles").update(update).eq("id", value: id).execute()
    }

    /// Home ZIP for showtime alerts. Stored in a private, owner-only table
    /// (not on the world-readable profiles row) via a SECURITY DEFINER RPC.
    /// Pass nil to turn theater alerts off.
    func setHomeZip(_ zip: String?) async {
        struct Params: Encodable {
            let p_zip: String?
            // Encode null explicitly (not omitted) so clearing actually clears.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(p_zip, forKey: .p_zip)
            }
            enum CodingKeys: String, CodingKey { case p_zip }
        }
        _ = try? await client.rpc("set_home_zip", params: Params(p_zip: zip)).execute()
    }

    /// Store the device's IANA timezone so the nightly job can send Tonight's
    /// Pick at ~7pm in the user's local time. Best-effort; called on launch.
    func setTimezone(_ identifier: String) async {
        struct Params: Encodable { let p_tz: String }
        _ = try? await client.rpc("set_timezone", params: Params(p_tz: identifier)).execute()
    }

    /// The user's saved theater-alert ZIP, if any (owner-only read).
    func homeZip() async -> String? {
        struct Row: Decodable { let home_zip: String? }
        guard let id = currentUserID else { return nil }
        let rows: [Row] = (try? await client.from("user_locations")
            .select("home_zip").eq("user_id", value: id).limit(1).execute().value) ?? []
        return rows.first?.home_zip
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

    func rankInsert(movieID: Int, bucket: Sentiment, position: Int, watchDate: Date? = nil,
                    stealth: Bool = false) async throws -> RankingRow {
        struct Params: Encodable {
            let p_movie_id: Int
            let p_bucket: String
            let p_position: Int
            let p_watch_date: String?
            let p_stealth: Bool
        }
        let dateString = watchDate.map { ISO8601DateFormatter.dateOnly.string(from: $0) }
        return try await client.rpc(
            "rank_insert",
            params: Params(p_movie_id: movieID, p_bucket: bucket.rawValue,
                           p_position: position, p_watch_date: dateString,
                           p_stealth: stealth)
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

    /// Optional "watch by" goal date (ISO yyyy-MM-dd, or nil to clear).
    func setWatchBy(movieID: Int, date: String?) async {
        struct Params: Encodable { let p_movie_id: Int; let p_watch_by: String? }
        do {
            _ = try await client.rpc("set_watch_by",
                                     params: Params(p_movie_id: movieID, p_watch_by: date)).execute()
        } catch {
            Self.logSwallowed("set_watch_by", error)
            await MainActor.run { ToastCenter.shared.saveFailed() }
        }
    }

    /// The "why I saved this" note on a Want to Watch entry.
    func setWatchlistNote(movieID: Int, note: String) async {
        struct Params: Encodable { let p_movie_id: Int; let p_note: String? }
        do {
            _ = try await client.rpc("set_watchlist_note",
                                     params: Params(p_movie_id: movieID, p_note: note)).execute()
        } catch {
            Self.logSwallowed("set_watchlist_note", error)
            await MainActor.run { ToastCenter.shared.saveFailed() }
        }
    }

    /// "Tell me when it's streaming" — client owns its rows; the daily
    /// availability cron does the watching. False = the toggle should
    /// revert (a silently-failed alert is worse than no alert).
    @discardableResult
    func setStreamingAlert(movieID: Int, enabled: Bool) async -> Bool {
        guard let me = currentUserID else { return false }
        struct Row: Encodable { let user_id: UUID; let movie_id: Int }
        do {
            if enabled {
                try await client.from("streaming_alerts")
                    .upsert(Row(user_id: me, movie_id: movieID),
                            onConflict: "user_id,movie_id")
                    .execute()
            } else {
                try await client.from("streaming_alerts").delete()
                    .eq("user_id", value: me).eq("movie_id", value: movieID)
                    .execute()
            }
            return true
        } catch {
            Self.logSwallowed("streaming_alerts", error)
            return false
        }
    }

    /// Stealth save: pull the 'watchlisted' event for this movie off the
    /// feed (mirror of hideRankEvent).
    func hideWatchlistEvent(movieID: Int) async {
        guard let me = currentUserID else { return }
        _ = try? await client.from("feed_events")
            .delete()
            .eq("user_id", value: me)
            .eq("movie_id", value: movieID)
            .eq("event_type", value: "watchlisted")
            .execute()
    }

    // MARK: - Growth: suggestions, contacts, invites

    func suggestedMembers() async throws -> [SuggestedMember] {
        struct Params: Encodable { let p_limit: Int }
        return try await client.rpc("suggested_members", params: Params(p_limit: 25))
            .execute().value
    }

    /// Save the user's (optional, unverified) phone number for contact
    /// matching. Returns false on failure so a required save can be retried.
    @discardableResult
    func setPhone(_ phone: String) async -> Bool {
        struct Params: Encodable { let p_phone: String }
        do { _ = try await client.rpc("set_phone", params: Params(p_phone: phone)).execute(); return true }
        catch { Self.logSwallowed("set_phone", error); return false }
    }

    /// The user's stored phone (for the settings field), or nil.
    func myPhone() async -> String? {
        (try? await client.rpc("my_phone").execute().value)
    }

    /// First-party engagement log for the in-feed Featured release card (our
    /// data only — never shared, no IDFA). Fire-and-forget; failures are
    /// swallowed so analytics can never disrupt the UI. action ∈
    /// "impression" | "open" | "add".
    func logFeaturedEvent(movieID: Int, action: String) {
        struct Params: Encodable { let p_movie_id: Int; let p_action: String }
        Task {
            _ = try? await client.rpc("log_featured_event",
                                      params: Params(p_movie_id: movieID, p_action: action)).execute()
        }
    }

    /// Whether a phone number is free (not already on another account). Callable
    /// before the account exists (anon), so signup can catch a duplicate on the
    /// phone step rather than after creating the account. Fails open on a network
    /// error — `set_phone` still enforces uniqueness server-side at save time.
    func phoneAvailable(_ phone: String) async -> Bool {
        struct Params: Encodable { let p_phone: String }
        do { return try await client.rpc("phone_available", params: Params(p_phone: phone)).execute().value }
        catch { Self.logSwallowed("phone_available", error); return true }
    }

    /// Which contact phone numbers belong to Cini members.
    func membersFromPhones(_ phones: [String]) async throws -> [SuggestedMember] {
        struct Params: Encodable { let p_phones: [String] }
        return try await client.rpc("members_from_phones", params: Params(p_phones: phones))
            .execute().value
    }

    /// Persist the caller's contacts as one-way hashes (the server hashes the
    /// normalized numbers — raw numbers and names are never stored) so we can
    /// notify them when one of those contacts later joins Cini.
    func storeContacts(_ phones: [String]) async {
        guard !phones.isEmpty else { return }
        struct Params: Encodable { let p_phones: [String] }
        _ = try? await client.rpc("store_contacts", params: Params(p_phones: phones)).execute()
    }

    /// Wipe the caller's stored contact hashes.
    func forgetContacts() async {
        _ = try? await client.rpc("forget_contacts").execute()
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
        do {
            return try await client.rpc("redeem_invite_from", params: Params(p_username: username))
                .execute().value
        } catch {
            Self.logSwallowed("redeem_invite_from", error)
            return false
        }
    }

    /// How many friends this user has brought to Cini — each one is a credit
    /// they can spend to unlock a feature.
    func referralCount() async -> Int {
        (try? await client.rpc("referral_count").execute().value) ?? 0
    }

    /// The feature keys this user has unlocked (aggregate_scores, …).
    func unlockedFeatures() async -> [String] {
        (try? await client.rpc("unlocked_features").execute().value) ?? []
    }

    /// Spend a referral credit to unlock a feature. Returns false if there's
    /// no unspent credit (or the key is unknown).
    @discardableResult
    func unlockFeature(_ feature: String) async -> Bool {
        struct Params: Encodable { let p_feature: String }
        do {
            return try await client.rpc("unlock_feature", params: Params(p_feature: feature))
                .execute().value
        } catch {
            Self.logSwallowed("unlock_feature", error)
            return false
        }
    }

    /// After you rank a title, notify the people who follow you and already
    /// rate that same title highly ("a friend rated one of your favorites").
    func notifyFriendsOfRating(movieID: Int) async {
        struct Params: Encodable { let p_movie_id: Int }
        do {
            _ = try await client.rpc("notify_friends_of_rating", params: Params(p_movie_id: movieID)).execute()
        } catch {
            Self.logSwallowed("notify_friends_of_rating", error)
        }
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
        var noteContainsSpoilers = false
        var personalNote: String?
        var labels: [String] = []
        var watchDate: String?
        var watchedWith: [String] = []
        var watchedWithIDs: [UUID] = []
        var watchedWhere: String?   // "home" | "theater"
        var watchCount = 0          // diary rewatches
        var performances: [(id: Int, name: String, profilePath: String?)] = []

        var isEmpty: Bool {
            note == nil && personalNote == nil && labels.isEmpty
                && watchDate == nil && watchedWith.isEmpty
                && watchedWhere == nil && watchCount == 0 && performances.isEmpty
        }
    }

    func myMovieDetails(movieID: Int) async -> MyMovieDetails? {
        guard let me = currentUserID else { return nil }

        struct NoteRow: Decodable { let body: String; let is_private: Bool; let contains_spoilers: Bool? }
        struct PerfRow: Decodable { let tmdb_person_id: Int; let person_name: String; let profile_path: String? }
        struct LabelName: Decodable { let name: String }
        struct LabelLink: Decodable { let labels: LabelName? }
        struct RankRow: Decodable {
            let watch_date: String?
            let watched_with: [UUID]?
            let watched_where: String?
            let ranking_labels: [LabelLink]?
        }

        async let notesTask: [NoteRow]? = try? client.from("notes")
            .select("body, is_private, contains_spoilers")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute().value
        async let perfsTask: [PerfRow]? = try? client.from("favorite_performances")
            .select("tmdb_person_id, person_name, profile_path")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute().value
        async let rankTask: RankRow? = try? client.from("rankings")
            .select("watch_date, watched_with, watched_where, ranking_labels(labels(name))")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .single().execute().value
        async let watchTask = watchSummary(movieID: movieID)

        var details = MyMovieDetails()
        for row in (await notesTask) ?? [] {
            if row.is_private {
                details.personalNote = row.body
            } else {
                details.note = row.body
                details.noteContainsSpoilers = row.contains_spoilers ?? false
            }
        }
        details.performances = ((await perfsTask) ?? []).map { ($0.tmdb_person_id, $0.person_name, $0.profile_path) }
        if let rank = await rankTask {
            details.watchDate = rank.watch_date
            details.watchedWhere = rank.watched_where
            details.labels = (rank.ranking_labels ?? []).compactMap { $0.labels?.name }
            if let with = rank.watched_with, !with.isEmpty {
                details.watchedWithIDs = with
                struct NameRow: Decodable { let username: String }
                let rows: [NameRow]? = try? await client.from("profiles")
                    .select("username").in("id", values: with).execute().value
                details.watchedWith = (rows ?? []).map(\.username)
            }
        }
        let watchInfo = await watchTask
        details.watchCount = watchInfo.count
        if details.watchDate == nil { details.watchDate = watchInfo.last }
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
        do {
            return try await client.rpc(
                "send_direct_rec",
                params: Params(p_recipient: recipient, p_movie_id: movieID,
                               p_note: trimmed.isEmpty ? nil : trimmed)
            ).execute().value
        } catch {
            Self.logSwallowed("send_direct_rec", error)
            return false
        }
    }

    func directRecs() async throws -> [DirectRecRow] {
        guard let me = currentUserID else { return [] }
        return try await client.from("direct_recs")
            .select("id, sender_id, movie_id, note, created_at, profiles!direct_recs_sender_id_fkey(username, display_name, avatar_url), movies!direct_recs_movie_id_fkey(*)")
            .eq("recipient_id", value: me)
            .order("created_at", ascending: false)
            .limit(20)
            .execute().value
    }

    func dismissDirectRec(id: UUID) async throws {
        _ = try await client.from("direct_recs").delete().eq("id", value: id).execute()
    }

    /// Pass on a friend's rec, optionally telling them why — dismisses the rec
    /// and (when a message is given) notifies the sender. (CIN-36)
    @discardableResult
    func passDirectRec(id: UUID, message: String?) async -> Bool {
        struct Params: Encodable { let p_rec_id: UUID; let p_message: String? }
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return try await client.rpc(
                "pass_direct_rec",
                params: Params(p_rec_id: id, p_message: (trimmed?.isEmpty == false) ? trimmed : nil)
            ).execute().value
        } catch {
            Self.logSwallowed("pass_direct_rec", error)
            return false
        }
    }

    // MARK: - Rec requests (ask friends for a rec)

    /// Returns how many friends were actually asked (the RPC skips
    /// non-followed and blocked members silently).
    func requestRecs(to recipients: [UUID], mediaKind: String?, genre: String?,
                     decade: Int?, maxRuntime: Int?, streamingProvider: String?,
                     note: String?) async -> Int {
        struct Params: Encodable {
            let p_recipients: [UUID]
            let p_media_kind: String?
            let p_genre: String?
            let p_note: String?
            let p_decade: Int?
            let p_max_runtime: Int?
            let p_streaming_provider: String?
        }
        do {
            return try await client.rpc(
                "request_recs",
                params: Params(p_recipients: recipients, p_media_kind: mediaKind,
                               p_genre: genre, p_note: note, p_decade: decade,
                               p_max_runtime: maxRuntime, p_streaming_provider: streamingProvider)
            ).execute().value
        } catch {
            Self.logSwallowed("request_recs", error)
            return 0
        }
    }

    /// Pending asks aimed at the current user (fulfilled ones filtered
    /// out client-side — the row carries fulfilled_at).
    func incomingRecRequests() async throws -> [RecRequestRow] {
        guard let me = currentUserID else { return [] }
        let rows: [RecRequestRow] = try await client.from("rec_requests")
            .select("id, requester_id, media_kind, genre, note, decade, max_runtime, streaming_provider, created_at, fulfilled_at, profiles!rec_requests_requester_id_fkey(username, display_name, avatar_url)")
            .eq("recipient_id", value: me)
            .order("created_at", ascending: false)
            .limit(20)
            .execute().value
        return rows.filter { $0.fulfilledAt == nil }
    }

    /// False means the ask is still pending server-side (the recs
    /// themselves already sent) — callers keep it visible so the
    /// responder can clear it later.
    @discardableResult
    func completeRecRequest(id: UUID) async -> Bool {
        struct Params: Encodable { let p_request_id: UUID }
        do {
            _ = try await client.rpc("complete_rec_request",
                                     params: Params(p_request_id: id)).execute()
            return true
        } catch {
            Self.logSwallowed("complete_rec_request", error)
            return false
        }
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

    /// Storage path(s) of the uploaded export(s) once the computer side is done.
    /// The import page can send more than one file in a session (e.g. a
    /// Letterboxd .zip and a Netflix .csv); they arrive as a comma-separated
    /// list in `path` and only become "ready" once the last one lands.
    func importUploadPaths(code: String) async -> [String] {
        struct Row: Decodable { let status: String; let path: String? }
        let row: Row? = try? await client.from("pending_imports")
            .select("status, path")
            .eq("code", value: code)
            .single().execute().value
        guard row?.status == "ready", let path = row?.path else { return [] }
        return path.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
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

    func upsertNote(movieID: Int, body: String, isPrivate: Bool,
                    containsSpoilers: Bool = false) async throws {
        guard let userID = currentUserID else { return }
        struct Row: Encodable {
            let user_id: UUID
            let movie_id: Int
            let body: String
            let is_private: Bool
            let contains_spoilers: Bool
        }
        try await client.from("notes")
            .upsert(Row(user_id: userID, movie_id: movieID, body: body,
                        is_private: isPrivate, contains_spoilers: containsSpoilers),
                    onConflict: "user_id,movie_id,is_private")
            .execute()
    }

    // MARK: - Moderation (App Store 1.2: report content, block members)

    /// Blocking is mutual invisibility — enforced server-side in can_view,
    /// so every feed, wall, and list filters automatically.
    func block(_ userID: UUID) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let blocker_id: UUID; let blocked_id: UUID }
        try await client.from("blocks")
            .upsert(Row(blocker_id: me, blocked_id: userID), onConflict: "blocker_id,blocked_id")
            .execute()
    }

    func unblock(_ userID: UUID) async throws {
        guard let me = currentUserID else { return }
        try await client.from("blocks").delete()
            .eq("blocker_id", value: me).eq("blocked_id", value: userID)
            .execute()
    }

    func blockedIDs() async -> Set<UUID> {
        guard let me = currentUserID else { return [] }
        struct Row: Decodable { let blocked_id: UUID }
        do {
            let rows: [Row] = try await client.from("blocks")
                .select("blocked_id").eq("blocker_id", value: me)
                .execute().value
            return Set(rows.map(\.blocked_id))
        } catch {
            // Failing open here would resurface blocked users — log loudly.
            Self.logSwallowed("blockedIDs", error)
            return []
        }
    }

    /// Returns true only if the report was actually recorded, so the UI can
    /// avoid telling the user "Reported" when nothing was written.
    @discardableResult
    func report(kind: String, subjectID: String, reason: String? = nil) async -> Bool {
        guard let me = currentUserID else { return false }
        struct Row: Encodable {
            let reporter_id: UUID
            let subject_kind: String
            let subject_id: String
            let reason: String?
        }
        do {
            _ = try await client.from("reports")
                .insert(Row(reporter_id: me, subject_kind: kind,
                            subject_id: subjectID, reason: reason))
                .execute()
            return true
        } catch {
            SupabaseService.logSwallowed("report", error)
            return false
        }
    }

    // MARK: - Custom lists

    func myLists() async throws -> [CustomList] {
        guard let me = currentUserID else { return [] }
        return try await lists(of: me)
    }

    func lists(of userID: UUID) async throws -> [CustomList] {
        try await client.from("custom_lists")
            .select("id, user_id, name, is_private, created_at, media_kind, custom_list_items(count)")
            .eq("user_id", value: userID)
            .order("created_at", ascending: false)
            .execute().value
    }

    /// One list by id (for an opened share link). Returns nil when it's not
    /// viewable — RLS only returns the row to the owner or an allowed follower.
    func list(id: UUID) async -> CustomList? {
        let rows: [CustomList]? = try? await client.from("custom_lists")
            .select("id, user_id, name, is_private, created_at, media_kind, custom_list_items(count)")
            .eq("id", value: id)
            .limit(1)
            .execute().value
        return rows?.first
    }

    func createList(name: String, mediaKind: String = "movie") async throws -> CustomList {
        guard let me = currentUserID else { throw URLError(.userAuthenticationRequired) }
        struct Row: Encodable { let user_id: UUID; let name: String; let media_kind: String }
        return try await client.from("custom_lists")
            .insert(Row(user_id: me, name: name,
                        media_kind: mediaKind == "tv" ? "tv" : "movie"))
            .select("id, user_id, name, is_private, created_at, media_kind, custom_list_items(count)")
            .single()
            .execute().value
    }

    func deleteList(_ id: UUID) async throws {
        try await client.from("custom_lists").delete().eq("id", value: id).execute()
    }

    func renameList(_ id: UUID, to name: String) async throws {
        struct Update: Encodable { let name: String }
        try await client.from("custom_lists").update(Update(name: name))
            .eq("id", value: id).execute()
    }

    /// Which of my lists already contain this movie (for the toggle sheet).
    func listIDs(containing movieID: Int) async -> Set<UUID> {
        struct Row: Decodable { let list_id: UUID }
        let rows: [Row] = (try? await client.from("custom_list_items")
            .select("list_id").eq("movie_id", value: movieID)
            .execute().value) ?? []
        return Set(rows.map(\.list_id))
    }

    func addToList(_ listID: UUID, movieID: Int) async throws {
        struct Row: Encodable { let list_id: UUID; let movie_id: Int }
        try await client.from("custom_list_items")
            .upsert(Row(list_id: listID, movie_id: movieID), onConflict: "list_id,movie_id")
            .execute()
    }

    func removeFromList(_ listID: UUID, movieID: Int) async throws {
        try await client.from("custom_list_items").delete()
            .eq("list_id", value: listID).eq("movie_id", value: movieID)
            .execute()
    }

    func listMovieIDs(_ listID: UUID) async throws -> [Int] {
        struct Row: Decodable { let movie_id: Int }
        let rows: [Row] = try await client.from("custom_list_items")
            .select("movie_id").eq("list_id", value: listID)
            .order("created_at", ascending: true)
            .execute().value
        return rows.map(\.movie_id)
    }

    // MARK: - Diary (every watch is its own row)

    /// One Letterboxd-import row for the bulk RPC below.
    struct ImportDetailItem: Encodable {
        let tmdb_id: Int
        let media_kind: String
        let title: String
        let release_year: Int?
        let poster_path: String?
        let review: String?
        let watched_on: String?
        /// Every diary date — rewatches each become their own entry.
        let watched_dates: [String]
    }

    /// Reviews land as public notes (never overwriting an in-app edit)
    /// and watch dates as diary rows — one round trip per 200 titles
    /// instead of hundreds of inserts.
    func importMovieDetails(_ items: [ImportDetailItem]) async throws {
        struct Params: Encodable { let p_items: [ImportDetailItem] }
        var start = 0
        while start < items.count {
            let chunk = Array(items[start..<min(start + 200, items.count)])
            try await client.rpc("import_movie_details", params: Params(p_items: chunk)).execute()
            start += 200
        }
    }

    func logWatch(movieID: Int, on date: Date, where location: String?) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable {
            let user_id: UUID
            let movie_id: Int
            let watched_on: String
            let watched_where: String?
        }
        try await client.from("watches")
            .insert(Row(user_id: me, movie_id: movieID,
                        watched_on: DateFormatter.posixDay.string(from: date),
                        watched_where: location))
            .execute()
    }

    func watches(of userID: UUID, limit: Int = 200) async throws -> [WatchRow] {
        try await client.from("watches")
            .select("id, movie_id, watched_on, watched_where")
            .eq("user_id", value: userID)
            .order("watched_on", ascending: false)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
    }

    /// (count, most recent date) for one movie — the "Watched 3×" line.
    func watchSummary(movieID: Int) async -> (count: Int, last: String?) {
        guard let me = currentUserID else { return (0, nil) }
        struct Row: Decodable { let watched_on: String }
        let rows: [Row] = (try? await client.from("watches")
            .select("watched_on")
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .order("watched_on", ascending: false)
            .execute().value) ?? []
        return (rows.count, rows.first?.watched_on)
    }

    /// Replace the favorite-performance set wholesale — editing can
    /// remove people, not just add them.
    func setPerformances(movieID: Int, cast: [CastMember]) async throws {
        guard let me = currentUserID else { return }
        try await client.from("favorite_performances").delete()
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .execute()
        try await addPerformances(movieID: movieID, cast: cast)
    }

    /// One batched upsert — a row per network call added up fast.
    func addPerformances(movieID: Int, cast: [CastMember]) async throws {
        guard let me = currentUserID, !cast.isEmpty else { return }
        struct Row: Encodable {
            let user_id: UUID
            let movie_id: Int
            let tmdb_person_id: Int
            let person_name: String
            let profile_path: String?
            let character_name: String?
        }
        let rows = cast.map {
            Row(user_id: me, movie_id: movieID, tmdb_person_id: $0.id,
                person_name: $0.name, profile_path: $0.profilePath,
                character_name: $0.character)
        }
        try await client.from("favorite_performances")
            .upsert(rows, onConflict: "user_id,movie_id,tmdb_person_id")
            .execute()
    }

    /// Editing can clear a note entirely.
    func deleteNote(movieID: Int, isPrivate: Bool) async throws {
        guard let me = currentUserID else { return }
        try await client.from("notes").delete()
            .eq("user_id", value: me).eq("movie_id", value: movieID)
            .eq("is_private", value: isPrivate)
            .execute()
    }

    func topPerformances(movieID: Int) async throws -> [PerformanceCount] {
        let rows: [PerformanceCount] = try await client.from("favorite_performances")
            .select("tmdb_person_id, person_name, profile_path")
            .eq("movie_id", value: movieID)
            .execute().value
        return Self.tallyPerformances(rows)
    }

    /// Tally recommendations per person, most recommended first.
    static func tallyPerformances(_ rows: [PerformanceCount]) -> [PerformanceCount] {
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

    /// The movie page's public aggregates in ONE round trip (was four) —
    /// the page assembles noticeably faster on cellular.
    struct MoviePageStats: Decodable {
        let community: CommunityScore?
        let histogram: [HistogramBin]
        let labels: [String]
        let performances: [PerformanceCount]
    }

    func moviePageStats(movieID: Int) async -> MoviePageStats? {
        struct Params: Encodable { let p_movie_id: Int }
        do {
            return try await client.rpc("movie_page_stats", params: Params(p_movie_id: movieID))
                .execute().value
        } catch {
            Self.logSwallowed("movie_page_stats", error)
            return nil
        }
    }

    // MARK: - Ranking enrichment

    func updateRanking(movieID: Int, watchedWith: [UUID], watchDate: Date?,
                       watchedWhere: String? = nil) async throws {
        guard let me = currentUserID else { return }
        struct Update: Encodable {
            let watched_with: [UUID]
            let watch_date: String?
            let watched_where: String?
        }
        let dateString = watchDate.map { ISO8601DateFormatter.dateOnly.string(from: $0) }
        try await client.from("rankings")
            .update(Update(watched_with: watchedWith, watch_date: dateString,
                           watched_where: watchedWhere))
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
            // profiles must name the FK: the likes table adds a second
            // feed_events↔profiles path and PostgREST rejects the bare
            // embed as ambiguous (PGRST201), silently emptying the feed.
            // likes/comments counts ride along so the profile Activity tab can
            // show interactive feed cards (like/comment), same as the feed.
            .select("*, profiles!feed_events_user_id_fkey(username, display_name, avatar_url), movies!feed_events_movie_id_fkey(*), likes(count), comments(count)")
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

    // MARK: Follow + approve (private accounts)

    /// Follow a public account instantly, or request a private one. Returns
    /// "followed", "requested", "blocked", or "self".
    @discardableResult
    func requestFollow(_ userID: UUID) async throws -> String {
        struct Params: Encodable { let p_target: UUID }
        return try await client.rpc("request_follow", params: Params(p_target: userID))
            .execute().value
    }

    /// True if I have a pending follow request out to this (private) account.
    func followRequestPending(_ userID: UUID) async -> Bool {
        guard let me = currentUserID else { return false }
        let response = try? await client.from("follow_requests")
            .select("*", head: true, count: .exact)
            .eq("requester_id", value: me).eq("target_id", value: userID)
            .execute()
        return (response?.count ?? 0) > 0
    }

    /// Cancel my outstanding follow request.
    func cancelFollowRequest(_ userID: UUID) async throws {
        guard let me = currentUserID else { return }
        try await client.from("follow_requests")
            .delete()
            .eq("requester_id", value: me).eq("target_id", value: userID)
            .execute()
    }

    /// Accept or decline a follow request someone sent me.
    func respondFollowRequest(requester: UUID, accept: Bool) async throws {
        struct Params: Encodable { let p_requester: UUID; let p_accept: Bool }
        try await client.rpc("respond_follow_request",
                             params: Params(p_requester: requester, p_accept: accept)).execute()
    }

    /// Pending follow requests sent to me.
    func incomingFollowRequests() async -> [FollowRequester] {
        (try? await client.rpc("incoming_follow_requests").execute().value) ?? []
    }

    func feed(limit: Int = 50) async throws -> [FeedEventRow] {
        // Your feed is the people you follow (plus yourself) — RLS alone
        // only handles VISIBILITY, which would surface every public
        // member's activity to everyone.
        guard let me = currentUserID else { return [] }
        struct Edge: Codable {
            let followingId: UUID
            enum CodingKeys: String, CodingKey { case followingId = "following_id" }
        }
        let edges: [Edge] = try await client.from("follows")
            .select("following_id")
            .eq("follower_id", value: me)
            .execute().value
        var ids = edges.map(\.followingId)
        ids.append(me)
        return try await client.from("feed_events")
            // profiles must name the FK: the likes table adds a second
            // feed_events↔profiles path and PostgREST rejects the bare
            // embed as ambiguous (PGRST201), silently emptying the feed.
            // likes(count)/comments(count) ride along as embedded aggregates —
            // both have a single FK to feed_events, so they're unambiguous, and
            // their RLS counts every like/comment on a visible event.
            .select("*, profiles!feed_events_user_id_fkey(username, display_name, avatar_url), movies!feed_events_movie_id_fkey(*), likes(count), comments(count)")
            .in("user_id", values: ids)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute().value
    }

    /// Attach each author's public note to their `ranked` feed events, matched
    /// by (author, movie) in one query — feed_events don't carry the note
    /// inline. `is_private = false` plus RLS keep this to notes the viewer is
    /// allowed to read, so private notes never leak onto the feed.
    func attachNotes(to events: [FeedEventRow]) async -> [FeedEventRow] {
        let ranked = events.enumerated().filter {
            $0.element.eventType == "ranked" && $0.element.movieId != nil
        }
        guard !ranked.isEmpty else { return events }
        let userIDs = Array(Set(ranked.map(\.element.userId)))
        let movieIDs = Array(Set(ranked.compactMap(\.element.movieId)))
        struct Row: Decodable {
            let userId: UUID
            let movieId: Int
            let body: String
            let containsSpoilers: Bool?
            enum CodingKeys: String, CodingKey {
                case userId = "user_id"
                case movieId = "movie_id"
                case body
                case containsSpoilers = "contains_spoilers"
            }
        }
        let rows: [Row] = (try? await client.from("notes")
            .select("user_id, movie_id, body, contains_spoilers")
            .in("user_id", values: userIDs)
            .in("movie_id", values: movieIDs)
            .eq("is_private", value: false)
            .execute().value) ?? []
        var byKey: [String: Row] = [:]
        for r in rows { byKey["\(r.userId.uuidString)-\(r.movieId)"] = r }

        var result = events
        for (idx, event) in ranked {
            guard let mid = event.movieId,
                  let note = byKey["\(event.userId.uuidString)-\(mid)"] else { continue }
            result[idx].note = note.body
            result[idx].noteContainsSpoilers = note.containsSpoilers ?? false
        }
        return result
    }

    /// "What people think → Everyone": every visible rating of this movie
    /// that has a public note, hearts/comments riding the ranked event.
    func publicNotes(movieID: Int) async throws -> [PublicNoteRow] {
        struct Params: Encodable { let p_movie_id: Int }
        return try await client.rpc("movie_public_notes",
                                    params: Params(p_movie_id: movieID))
            .execute().value
    }

    /// Everyone who liked a feed event — for the "who liked this" sheet.
    func likers(eventID: UUID) async -> [ProfileRow] {
        struct Row: Decodable { let userId: UUID
            enum CodingKeys: String, CodingKey { case userId = "user_id" } }
        let rows: [Row] = (try? await client.from("likes")
            .select("user_id")
            .eq("event_id", value: eventID)
            .execute().value) ?? []
        let ids = rows.map(\.userId)
        guard !ids.isEmpty else { return [] }
        return (try? await client.from("profiles")
            .select()
            .in("id", values: ids)
            .execute().value) ?? []
    }

    /// One member's public note for a movie — used by the comments header on a
    /// feed post, since feed events don't carry the note inline. RLS hides
    /// private notes and anything from members you can't view, so this only ever
    /// returns a note the viewer is allowed to read.
    func note(userID: UUID, movieID: Int) async -> String? {
        struct Row: Decodable { let body: String }
        let rows: [Row] = (try? await client.from("notes")
            .select("body")
            .eq("user_id", value: userID)
            .eq("movie_id", value: movieID)
            .eq("is_private", value: false)
            .limit(1)
            .execute().value) ?? []
        return rows.first?.body
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

    /// Idempotent on the *intended* state (`like`), not the observed one — a
    /// read-modify-write here let rapid taps double-insert or lose an unlike.
    /// The (user_id, event_id) primary key makes the upsert a no-op when already set.
    func toggleLike(eventID: UUID, like: Bool) async throws {
        guard let me = currentUserID else { return }
        if like {
            struct Row: Encodable { let user_id: UUID; let event_id: UUID }
            try await client.from("likes")
                .upsert(Row(user_id: me, event_id: eventID), onConflict: "user_id,event_id")
                .execute()
        } else {
            try await client.from("likes").delete()
                .eq("user_id", value: me).eq("event_id", value: eventID).execute()
        }
    }

    /// All of YOUR public notes — the reviews file in the export.
    struct MyNoteRow: Decodable {
        let movieId: Int
        let body: String
        enum CodingKeys: String, CodingKey {
            case movieId = "movie_id"
            case body
        }
    }

    func myPublicNoteRows() async throws -> [MyNoteRow] {
        guard let me = currentUserID else { return [] }
        return try await client.from("notes")
            .select("movie_id, body")
            .eq("user_id", value: me)
            .eq("is_private", value: false)
            .limit(1000)
            .execute().value
    }

    /// Delete YOUR OWN comment (RLS scopes the delete to user_id = you).
    func deleteComment(id: UUID) async throws {
        try await client.from("comments").delete().eq("id", value: id).execute()
    }

    func comment(eventID: UUID, body: String) async throws {
        guard let me = currentUserID else { return }
        struct Row: Encodable { let user_id: UUID; let event_id: UUID; let body: String }
        try await client.from("comments").insert(Row(user_id: me, event_id: eventID, body: body)).execute()
    }

    /// Notify members tagged with @username in a comment. Server-side it only
    /// notifies people the caller follows (and not the author), so passing extra
    /// ids is harmless.
    func notifyMention(eventID: UUID, userIDs: [UUID]) async {
        guard !userIDs.isEmpty else { return }
        struct Params: Encodable { let p_event_id: UUID; let p_user_ids: [UUID] }
        _ = try? await client.rpc("notify_mention",
                                  params: Params(p_event_id: eventID, p_user_ids: userIDs)).execute()
    }

    // MARK: - Recommendations

    /// Friend-powered recs: movies friends loved (weighted by taste match)
    /// that the user hasn't watched or watchlisted.
    func recsForUser(limit: Int = 30) async throws -> [RecRow] {
        struct Params: Encodable { let p_limit: Int }
        return try await client.rpc("recs_for_user", params: Params(p_limit: limit))
            .execute().value
    }

    /// The day's single "watch this tonight" pick for the signed-in user, or
    /// nil if there's nothing to recommend yet (brand-new account).
    func tonightPick() async throws -> TonightPickRow? {
        let rows: [TonightPickRow] = try await client.rpc("tonight_pick").execute().value
        return rows.first
    }

    /// Several Tonight's Pick candidates, so the app can keep the streamable
    /// ones for the 3-card stack.
    func tonightPicks(limit: Int = 8) async throws -> [TonightPickRow] {
        struct Params: Encodable { let p_limit: Int }
        return try await client.rpc("tonight_picks", params: Params(p_limit: limit)).execute().value
    }

    // MARK: - Watch Match (plan to watch together)

    /// Friends (you follow, not blocked) who also have this title on their
    /// Want to Watch — powers the movie page's "invite to watch together" row.
    func watchlistFriends(movieID: Int) async throws -> [WatchlistFriendRow] {
        struct Params: Encodable { let p_movie_id: Int }
        return try await client.rpc("movie_watchlist_friends", params: Params(p_movie_id: movieID))
            .execute().value
    }

    /// Friends currently watching a given show (with their progress).
    func watchingFriends(movieID: Int) async -> [WatchingFriendRow] {
        struct Params: Encodable { let p_movie_id: Int }
        return (try? await client.rpc("movie_watching_friends", params: Params(p_movie_id: movieID))
            .execute().value) ?? []
    }

    /// Propose watching a title together at a time; notifies the invitee.
    @discardableResult
    func proposeWatchPlan(movieID: Int, inviteeID: UUID, proposedAt: Date?) async throws -> UUID {
        struct Params: Encodable {
            let p_movie_id: Int
            let p_invitee: UUID
            let p_proposed_at: String?
        }
        let iso = proposedAt.map { ISO8601DateFormatter().string(from: $0) }
        return try await client.rpc("propose_watch_plan",
            params: Params(p_movie_id: movieID, p_invitee: inviteeID, p_proposed_at: iso))
            .execute().value
    }

    /// Accept/decline a plan, or propose a different time (pass newTime).
    func respondWatchPlan(planID: UUID, accept: Bool, newTime: Date? = nil) async throws {
        struct Params: Encodable {
            let p_plan_id: UUID
            let p_accept: Bool
            let p_new_time: String?
        }
        let iso = newTime.map { ISO8601DateFormatter().string(from: $0) }
        try await client.rpc("respond_watch_plan",
            params: Params(p_plan_id: planID, p_accept: accept, p_new_time: iso)).execute()
    }

    /// The most recent plan between me and a friend for a title, so the sheet
    /// can show "accept" vs "propose". RLS already scopes watch_plans to plans
    /// I'm part of, so we fetch my plans for this title and pick the latest one
    /// that involves this friend (avoids any ambiguous OR-filter encoding).
    func latestWatchPlan(movieID: Int, withUser: UUID) async throws -> WatchPlanRow? {
        let rows: [WatchPlanRow] = try await client.from("watch_plans")
            .select()
            .eq("movie_id", value: movieID)
            .order("created_at", ascending: false)
            .limit(20)
            .execute().value
        return rows.first { $0.proposerId == withUser || $0.inviteeId == withUser }
    }

    /// All my plans for a title (RLS scopes to plans I'm part of), so the movie
    /// page can label each friend's button (Invite / Pending / Respond / Planned).
    func watchPlans(movieID: Int) async -> [WatchPlanRow] {
        (try? await client.from("watch_plans")
            .select()
            .eq("movie_id", value: movieID)
            .order("created_at", ascending: false)
            .execute().value) ?? []
    }

    // MARK: - Currently Watching (binging signal)

    /// Mark/update where I am in a show (season/episode optional). Starting to
    /// watch supersedes Want to Watch (server drops the watchlist row).
    func setShowProgress(showID: Int, season: Int?, episode: Int?, caughtUp: Bool = false) async throws {
        struct Params: Encodable {
            let p_show_id: Int; let p_season: Int?; let p_episode: Int?; let p_caught_up: Bool
        }
        try await client.rpc("set_show_progress",
            params: Params(p_show_id: showID, p_season: season, p_episode: episode, p_caught_up: caughtUp))
            .execute()
    }

    func clearShowProgress(showID: Int) async throws {
        struct Params: Encodable { let p_show_id: Int }
        try await client.rpc("clear_show_progress", params: Params(p_show_id: showID)).execute()
    }

    /// Friends currently binging something — the "Friends are watching" shelf.
    func friendsWatching() async -> [FriendWatchingRow] {
        (try? await client.rpc("friends_watching").execute().value) ?? []
    }

    /// A member's current shows (mine, or a friend's if I can view them).
    func watching(for userID: UUID) async -> [WatchingRow] {
        struct Params: Encodable { let p_user: UUID }
        return (try? await client.rpc("watching_for", params: Params(p_user: userID)).execute().value) ?? []
    }

    /// Shows BOTH I and this member are currently watching.
    func mutualWatching(with userID: UUID) async -> [WatchingRow] {
        struct Params: Encodable { let p_user: UUID }
        return (try? await client.rpc("mutual_watching", params: Params(p_user: userID)).execute().value) ?? []
    }

    /// My progress on one show (nil = not currently marked watching).
    func myShowProgress(showID: Int) async -> ShowProgressRow? {
        guard let me = currentUserID else { return nil }
        let rows: [ShowProgressRow] = (try? await client.from("show_progress")
            .select("season, episode")
            .eq("user_id", value: me)
            .eq("show_id", value: showID)
            .limit(1)
            .execute().value) ?? []
        return rows.first
    }

    // MARK: - Shared watchlists

    // MARK: - Comments

    func comments(eventID: UUID) async throws -> [CommentRow] {
        var rows: [CommentRow] = try await client.from("comments")
            .select("*, profiles!comments_user_id_fkey(username, display_name, avatar_url), comment_likes(count)")
            .eq("event_id", value: eventID)
            .order("created_at")
            .limit(200)
            .execute().value
        // Seed each comment's like count from the embed and the viewer's own
        // liked state from one batched lookup.
        let likedIDs = await myLikedCommentIDs(rows.map(\.id))
        for i in rows.indices {
            rows[i].likeCount = rows[i].serverLikeCount
            rows[i].likedByMe = likedIDs.contains(rows[i].id)
        }
        return rows
    }

    /// Which of these comments the current user already liked — one query for
    /// the whole thread, so hearts survive a refresh.
    func myLikedCommentIDs(_ commentIDs: [UUID]) async -> Set<UUID> {
        guard let me = currentUserID, !commentIDs.isEmpty else { return [] }
        struct Row: Decodable { let comment_id: UUID }
        let rows: [Row] = (try? await client.from("comment_likes")
            .select("comment_id")
            .eq("user_id", value: me)
            .in("comment_id", values: commentIDs)
            .execute().value) ?? []
        return Set(rows.map(\.comment_id))
    }

    func toggleCommentLike(commentID: UUID, like: Bool) async throws {
        guard let me = currentUserID else { return }
        if like {
            struct Row: Encodable { let user_id: UUID; let comment_id: UUID }
            try await client.from("comment_likes")
                .upsert(Row(user_id: me, comment_id: commentID), onConflict: "user_id,comment_id")
                .execute()
        } else {
            try await client.from("comment_likes").delete()
                .eq("user_id", value: me).eq("comment_id", value: commentID).execute()
        }
    }

    // MARK: - Notifications

    func notifications(limit: Int = 50) async throws -> [NotificationRow] {
        guard let me = currentUserID else { return [] }
        return try await client.from("notifications")
            .select("*, actor:profiles!notifications_actor_id_fkey(username, display_name, avatar_url), movies!notifications_movie_id_fkey(title, poster_path)")
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

    /// Delete a single notification (swipe-to-delete in the bell).
    func deleteNotification(_ id: UUID) async {
        guard let me = currentUserID else { return }
        _ = try? await client.from("notifications").delete()
            .eq("id", value: id)
            .eq("recipient_id", value: me)
            .execute()
    }

    /// How many people have each title on their Want to Watch — privacy-safe
    /// aggregate counts (the `watchlist_counts` RPC).
    func watchlistCounts(movieIDs: [Int]) async -> [Int: Int] {
        guard !movieIDs.isEmpty else { return [:] }
        struct Row: Decodable { let movie_id: Int; let n: Int }
        struct Params: Encodable { let p_movie_ids: [Int] }
        let rows: [Row] = (try? await client.rpc("watchlist_counts",
                                                 params: Params(p_movie_ids: movieIDs))
            .execute().value) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.movie_id, $0.n) })
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

    /// Titles Cini members are ranking/bookmarking most over the last 2 weeks —
    /// the "Trending" search filter (CIN-34). Returns tmdb ids, most active first.
    func trendingTitles() async -> [Int] {
        struct Row: Decodable { let movieId: Int
            enum CodingKeys: String, CodingKey { case movieId = "movie_id" } }
        let rows: [Row] = (try? await client.rpc("trending_titles").execute().value) ?? []
        return rows.map(\.movieId)
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

/// Minimal requester info for the follow-request approval list.
struct FollowRequester: Codable, Identifiable, Hashable {
    let id: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    enum CodingKeys: String, CodingKey {
        case id, username
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

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

struct RecRequestRow: Decodable, Identifiable, Hashable {
    let id: UUID
    let requesterId: UUID
    let mediaKind: String?
    let genre: String?
    let note: String?
    var decade: Int?
    var maxRuntime: Int?
    var streamingProvider: String?
    let createdAt: Date
    let fulfilledAt: Date?
    let profiles: FeedEventRow.EmbeddedProfile?

    enum CodingKeys: String, CodingKey {
        case id, genre, note, profiles, decade
        case requesterId = "requester_id"
        case mediaKind = "media_kind"
        case maxRuntime = "max_runtime"
        case streamingProvider = "streaming_provider"
        case createdAt = "created_at"
        case fulfilledAt = "fulfilled_at"
    }

    /// "a comedy movie", "an action TV show", "something good" — the
    /// ask, spoken.
    var criteriaText: String {
        let kind = mediaKind == "tv" ? "TV show" : (mediaKind == "movie" ? "movie" : nil)
        func article(_ word: String) -> String {
            "aeiou".contains(word.lowercased().first ?? "x") ? "an" : "a"
        }
        var base: String
        switch (genre, kind) {
        case let (genre?, kind?):
            let phrase = "\(genre.lowercased()) \(kind)"
            base = "\(article(phrase)) \(phrase)"
        case let (genre?, nil): base = "something \(genre.lowercased())"
        case let (nil, kind?): base = "\(article(kind)) \(kind)"
        case (nil, nil): base = "something good"
        }
        // Tack on the extra filters in plain language.
        var extras: [String] = []
        if let decade { extras.append("from the \(decade)s") }
        if let maxRuntime { extras.append("under \(maxRuntime) min") }
        if let streamingProvider { extras.append("on \(streamingProvider)") }
        return extras.isEmpty ? base : base + " " + extras.joined(separator: ", ")
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

    // Synthesized Encodable would OMIT nil keys and PostgREST then can't
    // match the function (PGRST202) — encode explicit nulls so the full
    // parameter set always goes over the wire.
    enum CodingKeys: String, CodingKey {
        case p_tmdb_id, p_media_kind, p_title, p_release_year, p_poster_path,
             p_backdrop_path, p_genres, p_certification, p_runtime_minutes,
             p_director, p_overview
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(p_tmdb_id, forKey: .p_tmdb_id)
        try c.encode(p_media_kind, forKey: .p_media_kind)
        try c.encode(p_title, forKey: .p_title)
        try c.encode(p_release_year, forKey: .p_release_year)
        try c.encode(p_poster_path, forKey: .p_poster_path)
        try c.encode(p_backdrop_path, forKey: .p_backdrop_path)
        try c.encode(p_genres, forKey: .p_genres)
        try c.encode(p_certification, forKey: .p_certification)
        try c.encode(p_runtime_minutes, forKey: .p_runtime_minutes)
        try c.encode(p_director, forKey: .p_director)
        try c.encode(p_overview, forKey: .p_overview)
    }
}

struct RankingRow: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let movieId: Int
    let bucket: String
    let position: Int
    let score: Double
    /// Postgres `date` column — MUST stay String: the decoder's ISO8601
    /// strategies require a time part, so typing this `Date?` silently
    /// kills the whole row decode.
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
    var note: String?
    /// "Watch by" goal as a bare ISO date string (the column is a SQL
    /// `date`, so it won't decode as a timestamp Date).
    var watchBy: String?

    enum CodingKeys: String, CodingKey {
        case id, note
        case userId = "user_id"
        case movieId = "movie_id"
        case createdAt = "created_at"
        case watchBy = "watch_by"
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
    // PostgREST embedded aggregates: `likes(count)` / `comments(count)` arrive
    // as a single-element array of {count}. Nil when a query doesn't select them.
    let likes: [CountRow]?
    let comments: [CountRow]?
    // The author's public note for this title, attached client-side after the
    // feed loads (feed_events don't store it inline) so a ranking shows its
    // note Beli-style. Persisted in the disk cache so cold start keeps them.
    var note: String?
    var noteContainsSpoilers: Bool?

    var likeCount: Int { likes?.first?.count ?? 0 }
    var commentCount: Int { comments?.first?.count ?? 0 }

    struct CountRow: Codable, Hashable { let count: Int }

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
        case id, profiles, movies, payload, likes, comments
        case userId = "user_id"
        case eventType = "event_type"
        case movieId = "movie_id"
        case createdAt = "created_at"
        // Not columns on feed_events — absent from the server response (decode
        // to nil) and only written to the disk cache.
        case note
        case noteContainsSpoilers = "note_contains_spoilers"
    }
}

/// One row of the public "Everyone" wall on a movie page: a rating that
/// came with a note, plus its heart/comment counts.
struct PublicNoteRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let score: Double
    let note: String
    var containsSpoilers: Bool? = false
    let rankedAt: Date
    let eventId: UUID?
    var likeCount: Int
    var commentCount: Int
    var likedByMe: Bool

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, note, score
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case containsSpoilers = "contains_spoilers"
        case rankedAt = "ranked_at"
        case eventId = "event_id"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case likedByMe = "liked_by_me"
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
    var containsSpoilers: Bool? = false
    let rankedAt: Date
    // The ranking's feed event + counts, so the Friends wall is reactable
    // (CIN-40). `isSelf` marks the caller's own ranking.
    var eventId: UUID?
    var likeCount: Int = 0
    var commentCount: Int = 0
    var likedByMe: Bool = false
    var isSelf: Bool = false

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, score, note
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case containsSpoilers = "contains_spoilers"
        case rankedAt = "ranked_at"
        case eventId = "event_id"
        case likeCount = "like_count"
        case commentCount = "comment_count"
        case likedByMe = "liked_by_me"
        case isSelf = "is_self"
    }
}

/// A user-made list ("Best heist movies") with its item count embedded.
struct CustomList: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    var name: String
    let isPrivate: Bool
    let createdAt: Date
    /// "movie" or "tv" — a list holds ONE media type (nil on old rows
    /// decodes as movie).
    var mediaKind: String?
    let items: [CountRow]?

    var count: Int { items?.first?.count ?? 0 }
    var kind: String { mediaKind ?? "movie" }

    struct CountRow: Codable, Hashable { let count: Int }

    enum CodingKeys: String, CodingKey {
        case id, name
        case userId = "user_id"
        case mediaKind = "media_kind"
        case isPrivate = "is_private"
        case createdAt = "created_at"
        case items = "custom_list_items"
    }
}

/// One diary entry — a single watch of a movie on a date.
struct WatchRow: Codable, Identifiable, Hashable {
    let id: UUID
    let movieId: Int
    /// Postgres `date` column — MUST stay String ("2026-06-11"): the
    /// decoder's ISO8601 strategies require a time part, so `Date` here
    /// silently kills the whole row decode.
    let watchedOn: String
    let watchedWhere: String?

    enum CodingKeys: String, CodingKey {
        case id
        case movieId = "movie_id"
        case watchedOn = "watched_on"
        case watchedWhere = "watched_where"
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

/// A friend currently watching a show (movie page "N are watching" popup).
struct WatchingFriendRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let season: Int?
    let episode: Int?
    var caughtUp: Bool = false

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username, season, episode
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case caughtUp = "caught_up"
    }
}

/// A friend who also wants to watch a title (movie page invite row).
struct WatchlistFriendRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case username
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
    }
}

/// A friend currently watching a show — the "Friends are watching" shelf.
struct FriendWatchingRow: Codable, Identifiable, Hashable {
    let userId: UUID
    let username: String
    let displayName: String?
    let avatarUrl: String?
    let showId: Int
    let title: String
    let posterPath: String?
    let season: Int?
    let episode: Int?
    var caughtUp: Bool = false
    var startedAt: Date?
    let updatedAt: Date

    var id: String { "\(userId.uuidString)-\(showId)" }

    enum CodingKeys: String, CodingKey {
        case username, title, season, episode
        case userId = "user_id"
        case displayName = "display_name"
        case avatarUrl = "avatar_url"
        case showId = "show_id"
        case posterPath = "poster_path"
        case caughtUp = "caught_up"
        case startedAt = "started_at"
        case updatedAt = "updated_at"
    }
}

/// One of a member's currently-watching shows (profile shelf).
struct WatchingRow: Codable, Identifiable, Hashable {
    let showId: Int
    let title: String
    let posterPath: String?
    let season: Int?
    let episode: Int?
    let updatedAt: Date

    var id: Int { showId }

    enum CodingKeys: String, CodingKey {
        case title, season, episode
        case showId = "show_id"
        case posterPath = "poster_path"
        case updatedAt = "updated_at"
    }
}

/// My season/episode on a show (row present = currently watching).
struct ShowProgressRow: Codable, Hashable {
    let season: Int?
    let episode: Int?
}

/// A watch-together plan between two friends.
struct WatchPlanRow: Codable, Identifiable, Hashable {
    let id: UUID
    let movieId: Int
    let proposerId: UUID
    let inviteeId: UUID
    let proposedAt: Date?
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, status
        case movieId = "movie_id"
        case proposerId = "proposer_id"
        case inviteeId = "invitee_id"
        case proposedAt = "proposed_at"
    }
}

/// One row from the `tonight_pick` RPC — the movie plus the reason inputs.
struct TonightPickRow: Codable, Hashable {
    let movieId: Int
    let predicted: Double
    let friendCount: Int
    let topFriend: String?
    let source: String              // "watchlist" or "friends"

    enum CodingKeys: String, CodingKey {
        case movieId = "movie_id"
        case predicted
        case friendCount = "friend_count"
        case topFriend = "top_friend"
        case source
    }
}

struct NotificationRow: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: String
    let actorId: UUID?
    let movieId: Int?
    /// The feed event the notification points at — present for like/comment/
    /// mention, so tapping opens the right activity (and its comment thread).
    let eventId: UUID?
    let readAt: Date?
    let createdAt: Date
    let actor: ActorProfile?
    let movies: MovieStub?
    var message: String?   // free text for kinds that carry it (e.g. rec_passed)

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
        case id, kind, actor, movies, message
        case actorId = "actor_id"
        case movieId = "movie_id"
        case eventId = "event_id"
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
    /// PostgREST embedded `comment_likes(count)`.
    let commentLikes: [FeedEventRow.CountRow]?
    /// Filled in after fetch (server count seeds it; toggles own it after).
    var likeCount = 0
    /// Filled in after fetch from the viewer's liked-comment set.
    var likedByMe = false

    var serverLikeCount: Int { commentLikes?.first?.count ?? 0 }

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
        case commentLikes = "comment_likes"
    }
}
