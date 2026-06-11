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

    func note(_ icon: String, _ label: String,
              destination: AgentDestination? = nil) {
        actions.append(AgentAction(icon: icon, label: label, destination: destination))
    }

    func drain() -> [AgentAction] {
        defer { actions = [] }
        return actions
    }

    /// Best TMDB match for a spoken title ("dune 2021" works too).
    static func resolveMovie(_ title: String) async -> Movie? {
        let results = (try? await TMDBService.shared.search(query: title)) ?? []
        return results.first
    }

    /// Exact-username member lookup via the fuzzy search RPC.
    static func resolveMember(_ username: String) async -> ProfileRow? {
        let needle = username.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "@ "))
        let found = (try? await SupabaseService.shared.searchMembers(query: needle)) ?? []
        return found.first { $0.username.lowercased() == needle } ?? found.first
    }

    static func resolveList(named name: String) async -> CustomList? {
        let lists = (try? await SupabaseService.shared.myLists()) ?? []
        return lists.first { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
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
            return "\(movie.title) is already ranked on their list — no need to save it."
        }
        if await store.isOnWatchlist(movie.tmdbID) {
            return "\(movie.title) is already on their Want to Watch list."
        }
        await store.toggleWatchlist(movie: movie)
        await ChatAgentBridge.shared.note("bookmark.fill", "Saved \(movie.title)", destination: .wantToWatch)
        return "Done — \(movie.title) (\(movie.releaseYear.map(String.init) ?? "?")) is on their Want to Watch list."
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
        return "Removed \(movie.title) from their Want to Watch list."
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
        return "Created the list “\(list.name)” — it shows as a tab under My Lists."
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
        return "Added \(movie.title) to “\(list.name)”."
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
        return "Now following @\(member.username) — their activity joins the feed."
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
    let description = "Send a movie recommendation to a member the user follows, with an optional note."

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
        return "Deleted their rating for \(movie.title) — notes and diary entries stay."
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

#endif
