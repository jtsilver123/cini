import SwiftUI
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - The agent's hands

/// One thing the agent actually DID — rendered as a confirmation chip
/// under its reply so actions are always visible, never just claimed.
/// Tapping a chip takes you to what it touched.
struct AgentAction: Identifiable, Equatable, Hashable {
    let id = UUID()
    let icon: String
    let label: String
    var destination: AgentDestination?
}

/// Where a tapped receipt chip lands.
enum AgentDestination: Equatable, Hashable {
    case wantToWatch
    case listsHome
    case customList(UUID)
    case movie(Int)
    case member(UUID, String)
}

/// Ask Cini's tools run outside the SwiftUI tree; this bridge carries the
/// store, UI hooks (opening the rank flow), and the running record of
/// actions taken during a turn.
@MainActor
@Observable
final class ChatAgentBridge {
    static let shared = ChatAgentBridge()

    weak var store: RankingStore?
    var openLogFlow: ((Movie) -> Void)?
    private(set) var actions: [AgentAction] = []
    /// The last title a tool resolved this turn — the chat offers one-tap
    /// Save / Where-to-watch buttons for it under the reply.
    var lastDiscussedMovie: Movie?

    func note(_ icon: String, _ label: String,
              destination: AgentDestination? = nil) {
        actions.append(AgentAction(icon: icon, label: label, destination: destination))
    }

    func drain() -> [AgentAction] {
        defer { actions = [] }
        return actions
    }

    /// Best TMDB match for a spoken title — forgiving, like a friend who
    /// knows what you mean: "the new dune movie" still finds Dune, "up"
    /// finds Pixar's Up, "dune 2021" uses the year as a filter. Algorithm
    /// validated against live TMDB with a 20-phrase battery.
    static func resolveMovie(_ title: String) async -> Movie? {
        var query = title.trimmingCharacters(in: .whitespaces)
        query = strippedFiller(query)

        // A trailing year is a filter, not part of the title — search
        // ordering for "dune 2021" is unstable otherwise.
        var year: Int?
        let words = query.split(separator: " ").map(String.init)
        if let last = words.last, last.count == 4, let parsed = Int(last),
           (1900...2099).contains(parsed), words.count > 1 {
            year = parsed
            query = words.dropLast().joined(separator: " ")
        }

        if let hit = await bestHit(query, year: year) { return await remember(hit) }

        // TMDB has no fuzzy matching — shave a trailing typo character.
        if query.count > 5 {
            if let hit = await bestHit(String(query.dropLast()), year: year) { return await remember(hit) }
            if let hit = await bestHit(String(query.dropLast(2)), year: year) { return await remember(hit) }
        }

        // Last resort: the most distinctive word ("that anatomy courtroom
        // one" → a real search term).
        let stop: Set<String> = ["that", "this", "with", "from", "about", "movie",
                                 "film", "show", "new", "old", "one", "the"]
        let lowered = query.lowercased()
        var longest = ""
        for piece in lowered.split(separator: " ") {
            let word = String(piece)
            if word.count > 3, !stop.contains(word), word.count > longest.count {
                longest = word
            }
        }
        if !longest.isEmpty, longest != lowered {
            if let hit = await bestHit(longest, year: year) { return await remember(hit) }
        }
        return nil
    }

    /// Leading/trailing chatter that poisons search ("the new …", "… movie").
    private static func strippedFiller(_ text: String) -> String {
        var query = text
        var changed = true
        while changed {
            changed = false
            for prefix in ["the movie ", "the film ", "the tv show ", "the show ",
                           "the new ", "that new ", "new "] {
                if query.lowercased().hasPrefix(prefix), query.count > prefix.count {
                    query = String(query.dropFirst(prefix.count))
                    changed = true
                }
            }
        }
        for suffix in [" the movie", " the film", " movie", " film", " tv show", " show"] {
            if query.lowercased().hasSuffix(suffix) {
                query = String(query.dropLast(suffix.count))
            }
        }
        return query
    }

    /// First result whose title EXACTLY matches the query (so "up" finds
    /// Up, not this week's noisiest new release) — else the top result.
    private static func bestHit(_ query: String, year: Int?) async -> Movie? {
        let results = (try? await TMDBService.shared.search(query: query, year: year)) ?? []
        guard !results.isEmpty else { return nil }
        let needle = query.lowercased()
        for movie in results.prefix(10) {
            if movie.title.lowercased() == needle { return movie }
        }
        return results.first
    }

    private static func remember(_ movie: Movie) async -> Movie {
        await MainActor.run { ChatAgentBridge.shared.lastDiscussedMovie = movie }
        return movie
    }

    /// Exact-username member lookup via the fuzzy search RPC.
    static func resolveMember(_ username: String) async -> ProfileRow? {
        let needle = username.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        let found = (try? await SupabaseService.shared.searchMembers(query: needle)) ?? []
        return found.first { $0.username.lowercased() == needle } ?? found.first
    }

    /// Forgiving list lookup: exact name, then containment, then word
    /// overlap and fuzzy similarity — "my heist list" finds
    /// "Best Heist Movies".

    /// "id → Title (Year)" for a batch of movie ids, server-cache backed.
    static func titles(for ids: [Int]) async -> [Int: String] {
        let rows = (try? await SupabaseService.shared.movies(ids: ids)) ?? []
        return Dictionary(uniqueKeysWithValues: rows.map { row in
            let movie = row.asMovie
            let year = movie.releaseYear.map { " (\($0))" } ?? ""
            return (movie.tmdbID, movie.title + year)
        })
    }

    private static let listStopWords: Set<String> = [
        "my", "the", "a", "of", "list", "lists", "movie", "movies", "film", "films",
    ]

    private static func significantWords(in text: String) -> Set<String> {
        let words = text.lowercased().split(separator: " ").map(String.init)
        return Set(words).subtracting(listStopWords)
    }

    /// How well a spoken name matches a list name (0–1). Small named
    /// helpers — the one-expression version timed out the type checker.
    static func listMatchScore(needle: String, candidate: String) -> Double {
        var score: Double = Fuzzy.similarity(query: needle, candidate: candidate)
        if candidate.localizedCaseInsensitiveContains(needle)
            || needle.localizedCaseInsensitiveContains(candidate) {
            score = max(score, 0.85)
        }
        let overlap = significantWords(in: needle).intersection(significantWords(in: candidate))
        if !overlap.isEmpty {
            score = max(score, 0.65 + 0.15 * Double(overlap.count))
        }
        return score
    }

    /// Forgiving list lookup: exact name, then containment, word overlap,
    /// and fuzzy similarity — "my heist list" finds "Best Heist Movies".
    static func resolveList(named name: String) async -> CustomList? {
        let lists = (try? await SupabaseService.shared.myLists()) ?? []
        let needle = name.trimmingCharacters(in: .whitespaces)
        if let exact = lists.first(where: {
            $0.name.localizedCaseInsensitiveCompare(needle) == .orderedSame
        }) { return exact }

        var bestList: CustomList?
        var bestScore: Double = 0
        for list in lists {
            let score = listMatchScore(needle: needle, candidate: list.name)
            if score > bestScore {
                bestScore = score
                bestList = list
            }
        }
        return bestScore >= 0.6 ? bestList : nil
    }
}

#if canImport(FoundationModels)

// MARK: - Tools: everything a user can do by tapping, the agent can do too.

@available(iOS 26.0, *)
struct SaveToWatchlistTool: Tool {
    let name = "saveToWantToWatch"
    let description = "Save a movie or show to the user's Want to Watch list."

    @Generable
    struct Arguments {
        @Guide(description: "The movie or show title (add the year if ambiguous)")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        if await store.isWatched(movie.tmdbID) {
            return "\(movie.title) is already ranked — it\u{2019}s been watched, no need to save it."
        }
        if await store.isOnWatchlist(movie.tmdbID) {
            return "\(movie.title) is already saved on the Want to Watch list."
        }
        await store.toggleWatchlist(movie: movie)
        await ChatAgentBridge.shared.note("bookmark.fill", "Saved \(movie.title)", destination: .wantToWatch)
        return "Saved! \(movie.title) (\(movie.releaseYear.map(String.init) ?? "?")) is on the Want to Watch list now."
    }
}

@available(iOS 26.0, *)
struct RemoveFromWatchlistTool: Tool {
    let name = "removeFromWantToWatch"
    let description = "Remove a movie or show from the user's Want to Watch list."

    @Generable
    struct Arguments {
        @Guide(description: "The title to remove")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        guard await store.isOnWatchlist(movie.tmdbID) else {
            return "\(movie.title) isn't on their Want to Watch list."
        }
        await store.toggleWatchlist(movie: movie)
        await ChatAgentBridge.shared.note("bookmark.slash", "Removed \(movie.title)", destination: .wantToWatch)
        return "Gone — \(movie.title) is off the Want to Watch list."
    }
}

@available(iOS 26.0, *)
struct CreateListTool: Tool {
    let name = "createList"
    let description = "Create a new custom movie list for the user."

    @Generable
    struct Arguments {
        @Guide(description: "The list's name, e.g. Best heist movies")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        let trimmed = arguments.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "The list needs a name." }
        if await ChatAgentBridge.resolveList(named: trimmed) != nil {
            return "They already have a list called \(trimmed)."
        }
        guard let list = try? await SupabaseService.shared.createList(name: trimmed) else {
            return "Couldn't create the list — connection trouble."
        }
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        await ChatAgentBridge.shared.note("list.star", "Created “\(list.name)”", destination: .customList(list.id))
        return "Made it! “\(list.name)” now lives as a tab under My Lists."
    }
}

@available(iOS 26.0, *)
struct AddToListTool: Tool {
    let name = "addMovieToList"
    let description = "Add a movie to one of the user's custom lists (creates the list if it doesn't exist)."

    @Generable
    struct Arguments {
        @Guide(description: "The movie or show title")
        var title: String
        @Guide(description: "The custom list's name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        var list = await ChatAgentBridge.resolveList(named: arguments.listName)
        if list == nil {
            list = try? await SupabaseService.shared.createList(
                name: arguments.listName.trimmingCharacters(in: .whitespaces))
            if list != nil {
                await ChatAgentBridge.shared.note("list.star", "Created “\(arguments.listName)”")
            }
        }
        guard let list else { return "Couldn't find or create that list." }
        try? await SupabaseService.shared.cacheMovie(movie)
        do {
            try await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID)
        } catch {
            return "Couldn't add \(movie.title) — connection trouble."
        }
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        await ChatAgentBridge.shared.note("plus.circle.fill", "\(movie.title) → “\(list.name)”", destination: .customList(list.id))
        return "Filed! \(movie.title) is on “\(list.name)”."
    }
}

@available(iOS 26.0, *)
struct RemoveFromListTool: Tool {
    let name = "removeMovieFromList"
    let description = "Remove a movie from one of the user's custom lists."

    @Generable
    struct Arguments {
        @Guide(description: "The movie or show title")
        var title: String
        @Guide(description: "The custom list's name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let list = await ChatAgentBridge.resolveList(named: arguments.listName) else {
            return "They don't have a list called \(arguments.listName)."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        try? await SupabaseService.shared.removeFromList(list.id, movieID: movie.tmdbID)
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        await ChatAgentBridge.shared.note("minus.circle", "\(movie.title) ✕ “\(list.name)”", destination: .customList(list.id))
        return "Removed \(movie.title) from “\(list.name)”."
    }
}

@available(iOS 26.0, *)
struct DeleteListTool: Tool {
    let name = "deleteList"
    let description = "Permanently delete one of the user's custom lists. Only call after the user explicitly confirms."

    @Generable
    struct Arguments {
        @Guide(description: "The custom list's name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let list = await ChatAgentBridge.resolveList(named: arguments.listName) else {
            return "They don't have a list called \(arguments.listName)."
        }
        do {
            try await SupabaseService.shared.deleteList(list.id)
        } catch {
            return "Couldn't delete the list — connection trouble."
        }
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        await ChatAgentBridge.shared.note("trash", "Deleted “\(list.name)”", destination: .listsHome)
        return "Deleted the list “\(list.name)”."
    }
}

@available(iOS 26.0, *)
struct SearchMembersTool: Tool {
    let name = "searchMembers"
    let description = "Find Cini members by username or name."

    @Generable
    struct Arguments {
        @Guide(description: "Username or name to search for")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        let found = (try? await SupabaseService.shared.searchMembers(query: arguments.query)) ?? []
        guard !found.isEmpty else { return "No members match \"\(arguments.query)\"." }
        return found.prefix(5).map {
            "@\($0.username)" + ($0.displayName.isEmpty ? "" : " (\($0.displayName))")
        }.joined(separator: ", ")
    }
}

@available(iOS 26.0, *)
struct FollowMemberTool: Tool {
    let name = "followMember"
    let description = "Follow a Cini member by username."

    @Generable
    struct Arguments {
        @Guide(description: "The member's username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        do {
            try await SupabaseService.shared.follow(member.id)
        } catch {
            return "Couldn't follow @\(member.username) — connection trouble."
        }
        await FriendsCache.shared.refresh()
        await ChatAgentBridge.shared.note("person.badge.plus", "Followed @\(member.username)", destination: .member(member.id, member.username))
        return "Following @\(member.username) now — their rankings start showing up in the feed."
    }
}

@available(iOS 26.0, *)
struct UnfollowMemberTool: Tool {
    let name = "unfollowMember"
    let description = "Unfollow a Cini member by username."

    @Generable
    struct Arguments {
        @Guide(description: "The member's username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        try? await SupabaseService.shared.unfollow(member.id)
        await FriendsCache.shared.refresh()
        await ChatAgentBridge.shared.note("person.badge.minus", "Unfollowed @\(member.username)", destination: .member(member.id, member.username))
        return "Unfollowed @\(member.username)."
    }
}

@available(iOS 26.0, *)
struct SendRecTool: Tool {
    let name = "sendRecommendation"
    let description = "Send a movie recommendation TO ANOTHER CINI MEMBER (a person, by @username). Never use this to find where to watch something — that's lookupMovie."

    @Generable
    struct Arguments {
        @Guide(description: "The recipient's username")
        var username: String
        @Guide(description: "The movie or show title")
        var title: String
        @Guide(description: "A short personal note, or empty")
        var note: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        try? await SupabaseService.shared.cacheMovie(movie)
        let sent = await SupabaseService.shared.sendDirectRec(
            to: member.id, movieID: movie.tmdbID, note: arguments.note)
        guard sent else {
            return "Couldn't send — recs only go to people they follow. Offer to follow @\(member.username) first."
        }
        await ChatAgentBridge.shared.note("paperplane.fill", "\(movie.title) → @\(member.username)", destination: .member(member.id, member.username))
        return "Sent \(movie.title) to @\(member.username)."
    }
}

@available(iOS 26.0, *)
struct StartRankingTool: Tool {
    let name = "startRanking"
    let description = "Open the ranking flow for a movie the user has watched, so they can rank it with comparisons."

    @Generable
    struct Arguments {
        @Guide(description: "The movie or show title to rank")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        await MainActor.run {
            ChatAgentBridge.shared.store?.cache(movie)
            ChatAgentBridge.shared.openLogFlow?(movie)
            ChatAgentBridge.shared.note("plus.circle", "Ranking \(movie.title)", destination: .movie(movie.tmdbID))
        }
        return "The ranking flow for \(movie.title) just opened on screen — they'll pick how they felt and compare. Keep your reply to one short line."
    }
}

@available(iOS 26.0, *)
struct DeleteRatingTool: Tool {
    let name = "deleteRating"
    let description = "Delete the user's rating for a movie, removing it from their ranked list. Only call after the user explicitly confirms."

    @Generable
    struct Arguments {
        @Guide(description: "The ranked movie's title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        guard await store.isWatched(movie.tmdbID) else {
            return "\(movie.title) isn't on their ranked list."
        }
        guard await store.removeRanking(movieID: movie.tmdbID) else {
            return "Couldn't delete the rating — connection trouble."
        }
        await ChatAgentBridge.shared.note("trash", "Deleted rating for \(movie.title)", destination: .movie(movie.tmdbID))
        return "Done — the \(movie.title) rating is gone. Notes and diary entries are safe."
    }
}

@available(iOS 26.0, *)
struct MyListsTool: Tool {
    let name = "getMyLists"
    let description = "List the user's custom lists with how many titles each holds."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let lists = (try? await SupabaseService.shared.myLists()) ?? []
        guard !lists.isEmpty else { return "They have no custom lists yet — just the built-in Want to Watch." }
        return lists.map { "\($0.name) (\($0.count) titles)" }.joined(separator: "; ")
    }
}


@available(iOS 26.0, *)
struct FriendWatchedTool: Tool {
    let name = "getFriendRankings"
    let description = "What a member has watched and ranked, best first, with their scores."

    @Generable
    struct Arguments {
        @Guide(description: "The member's username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        let rankings = (try? await SupabaseService.shared.rankings(userID: member.id)) ?? []
        guard !rankings.isEmpty else {
            return "Nothing visible on @\(member.username)'s ranked list — it's empty, or their profile is private (following them unlocks it)."
        }
        let top = Array(rankings.sorted { $0.score > $1.score }.prefix(12))
        let names = await ChatAgentBridge.titles(for: top.map(\.movieId))
        var lines: [String] = []
        for row in top {
            guard let title = names[row.movieId] else { continue }
            lines.append(title + " — " + String(format: "%.1f", row.score))
        }
        let more = rankings.count > 12 ? " …plus \(rankings.count - 12) more." : ""
        return "@\(member.username) has ranked \(rankings.count): " + lines.joined(separator: "; ") + more
    }
}

@available(iOS 26.0, *)
struct FriendWantToWatchTool: Tool {
    let name = "getFriendWantToWatch"
    let description = "What's on a member's Want to Watch list."

    @Generable
    struct Arguments {
        @Guide(description: "The member's username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        let rows = (try? await SupabaseService.shared.watchlist(userID: member.id)) ?? []
        guard !rows.isEmpty else {
            return "Nothing visible on @\(member.username)'s Want to Watch — it's empty, or their profile is private."
        }
        let names = await ChatAgentBridge.titles(for: rows.map(\.movieId))
        let listed = rows.prefix(15).compactMap { names[$0.movieId] }
        let more = rows.count > 15 ? " …plus \(rows.count - 15) more." : ""
        return "@\(member.username) wants to watch \(rows.count): " + listed.joined(separator: ", ") + more
    }
}

@available(iOS 26.0, *)
struct FriendOverlapTool: Tool {
    let name = "getOverlapWithFriend"
    let description = "Movies the user and a member share: both watched (with both scores) and both want to watch — perfect for movie-night picks."

    @Generable
    struct Arguments {
        @Guide(description: "The member's username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        let theirRankings = (try? await SupabaseService.shared.rankings(userID: member.id)) ?? []
        let theirWatchlist = (try? await SupabaseService.shared.watchlist(userID: member.id)) ?? []

        var bothWatched: [(id: Int, mine: Double, theirs: Double)] = []
        for row in theirRankings {
            let item = await store.scoredItem(for: row.movieId)
            if let mine = item?.score {
                bothWatched.append((id: row.movieId, mine: mine, theirs: row.score))
            }
        }
        var bothWant: [Int] = []
        for row in theirWatchlist {
            let saved = await store.isOnWatchlist(row.movieId)
            if saved { bothWant.append(row.movieId) }
        }

        if bothWatched.isEmpty && bothWant.isEmpty {
            return "No overlap with @\(member.username) yet — either nothing shared, or their profile is private."
        }
        let names = await ChatAgentBridge.titles(
            for: bothWatched.map(\.id) + bothWant)
        var parts: [String] = []
        if !bothWatched.isEmpty {
            let ranked = Array(bothWatched.sorted { $0.theirs > $1.theirs }.prefix(10))
            var lines: [String] = []
            for entry in ranked {
                guard let title = names[entry.id] else { continue }
                let mine = String(format: "%.1f", entry.mine)
                let theirs = String(format: "%.1f", entry.theirs)
                lines.append(title + " (you " + mine + ", them " + theirs + ")")
            }
            parts.append("Both watched: " + lines.joined(separator: "; "))
        }
        if !bothWant.isEmpty {
            let listed = bothWant.prefix(10).compactMap { names[$0] }
            parts.append("Both want to watch (movie-night gold): " + listed.joined(separator: ", "))
        }
        return parts.joined(separator: ". ")
    }
}

#endif
