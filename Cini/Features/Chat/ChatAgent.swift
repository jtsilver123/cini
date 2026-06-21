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
    /// The user's latest message — the consent gate for mutating tools.
    var lastUserPrompt = ""

    /// Live "using tools" feed, Claude-style: each tool announces what
    /// it's doing the moment it starts, and the thinking bubble renders
    /// the steps as they happen.
    private(set) var steps: [ToolStep] = []

    struct ToolStep: Identifiable, Equatable {
        let id = UUID()
        let icon: String
        let label: String
        var done = false
    }

    /// Call at the top of a tool's work — marks any prior step done and
    /// shows this one as active. Consecutive identical steps collapse to
    /// one: if the model loops on a tool (e.g. retries "Building Comedy"),
    /// the checklist shows it once, not a dozen times.
    func step(_ icon: String, _ label: String) {
        if let last = steps.last, last.label == label { return }
        for index in steps.indices { steps[index].done = true }
        steps.append(ToolStep(icon: icon, label: label))
    }

    func startTurn() {
        steps = []
        lastDiscussedMovie = nil
    }

    func finishSteps() {
        for index in steps.indices { steps[index].done = true }
    }

    /// Deterministic consent check: prompt-rule discipline alone didn't
    /// stop the model from saving its own recs, so the save tool refuses
    /// unless the user's own words asked for it.
    var promptAsksToSave: Bool {
        let prompt = lastUserPrompt.lowercased()
        let words = Set(prompt.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let saveWords = ["save", "add", "bookmark", "watchlist", "queue",
                         "yes", "yeah", "sure", "okay", "ok", "yep"]
        if saveWords.contains(where: { words.contains($0) }) { return true }
        return prompt.contains("my list") || prompt.contains("do it")
    }

    /// Consent gate for adding a title to a custom list — broader verbs
    /// than save ("put it on my heist list", "throw X on date night"),
    /// plus a named list or an affirmation. Blocks the model from filing
    /// its own recs onto a list the user didn't ask about.
    var promptAsksToAdd: Bool {
        let prompt = lastUserPrompt.lowercased()
        let words = Set(prompt.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let addWords = ["add", "put", "throw", "stick", "drop", "file", "save",
                        "queue", "yes", "yeah", "sure", "okay", "ok", "yep"]
        if addWords.contains(where: { words.contains($0) }) { return true }
        return prompt.contains("list") || prompt.contains("do it")
    }

    /// Fail-safe gate for DESTRUCTIVE tools — the user's words must
    /// command or confirm it, or the model is told to ask first.
    var promptConfirmsDestruction: Bool {
        let prompt = lastUserPrompt.lowercased()
        let words = Set(prompt.split(whereSeparator: { !$0.isLetter }).map(String.init))
        let confirmWords = ["delete", "remove", "yes", "yeah", "sure",
                            "okay", "ok", "yep", "confirm", "wipe", "clear"]
        if confirmWords.contains(where: { words.contains($0) }) { return true }
        return prompt.contains("do it") || prompt.contains("go ahead")
    }

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
        "that", "this", "with", "one", "ones", "for", "me",
    ]

    /// Singularized so "heists" overlaps "heist" — stop words are stored
    /// in both forms, so they stay filtered either way.
    private static func normalized(_ word: String) -> String {
        if word.count > 3, word.hasSuffix("s") { return String(word.dropLast()) }
        return word
    }

    private static func significantWords(in text: String) -> Set<String> {
        var result: Set<String> = []
        for piece in text.lowercased().split(separator: " ") {
            let word = String(piece)
            if listStopWords.contains(word) { continue }
            result.insert(normalized(word))
        }
        return result
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
    let description = "Save a movie or show to Want to Watch. Only when they explicitly ask — never for your own recs."

    @Generable
    struct Arguments {
        @Guide(description: "The title (year helps)")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        // Hard consent gate — the .47-era screenshot showed the model
        // saving its own rec, which also disabled the user's save button.
        guard await ChatAgentBridge.shared.promptAsksToSave else {
            return "STOP — they did not ask you to save anything. Recommend only; a Want to Watch button appears under your reply for them to tap."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        if await store.isWatched(movie.tmdbID) {
            return "\(movie.title) is already ranked — it\u{2019}s been watched, no need to save it."
        }
        if await store.isOnWatchlist(movie.tmdbID) {
            return "\(movie.title) is already on their Want to Watch list."
        }
        // Announce only now that the bookmark will really happen.
        await ChatAgentBridge.shared.step("bookmark.fill", "Bookmarking \(movie.title)")
        await store.toggleWatchlist(movie: movie)
        await ChatAgentBridge.shared.note("bookmark.fill", "Bookmarked \(movie.title)", destination: .wantToWatch)
        return "Bookmarked! \(movie.title) (\(movie.releaseYear.map(String.init) ?? "?")) is on their Want to Watch list now."
    }
}

@available(iOS 26.0, *)
struct RemoveFromWatchlistTool: Tool {
    let name = "removeFromWantToWatch"
    let description = "Remove a title from Want to Watch."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("bookmark.slash", "Updating Want to Watch")
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
    let description = "Create a custom list."

    @Generable
    struct Arguments {
        @Guide(description: "List name")
        var name: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("list.star", "Creating the list")
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

/// "Make me a list of the best A24 movies" — one call instead of nine.
/// Themed asks (genre, studio, mood, era, awards) ride the model's own
/// film knowledge, TMDB-verified so hallucinations fall out. Person asks
/// ("shows with Neil Patrick Harris") ride the REAL filmography instead
/// of model memory.
@available(iOS 26.0, *)
struct CurateListTool: Tool {
    let name = "curateList"
    let description = "ONLY when they explicitly say make/build me a LIST. Pass 5-8 titles for a theme, OR a person name for 'movies/shows with X'. Never for 'what should I watch' — that's one pick, not a list."

    @Generable
    struct Arguments {
        @Guide(description: "List name, e.g. Best A24 Movies")
        var name: String
        @Guide(description: "5-8 titles that fit the theme (skip when person is set)")
        var titles: [String]?
        @Guide(description: "Actor or director name, only for 'movies/shows with X' asks")
        var person: String?
        @Guide(description: "Limit kind: movie or tv (optional)")
        var kind: String?
    }

    func call(arguments: Arguments) async throws -> String {
        let trimmed = arguments.name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "The list needs a name." }

        // Person asks come from data, not memory.
        var pool: [Movie] = []
        if let person = arguments.person?.trimmingCharacters(in: .whitespaces), !person.isEmpty {
            if let personID = try? await TMDBService.shared.personID(matching: person) {
                pool = (try? await TMDBService.shared.filmography(personID: personID)) ?? []
                if arguments.kind == "tv" { pool = pool.filter { $0.mediaKind == "tv" } }
                if arguments.kind == "movie" { pool = pool.filter { $0.mediaKind != "tv" } }
                pool = Array(pool.prefix(8))
            }
            if pool.isEmpty {
                return "Couldn't find anyone called \"\(person)\" with credits — check the name."
            }
        }
        // Resolve everything FIRST: the list's media type is inferred
        // from what's actually going on it (lists hold one type).
        if pool.isEmpty {
            for title in (arguments.titles ?? []).prefix(10) {
                guard let movie = await ChatAgentBridge.resolveMovie(title) else { continue }
                pool.append(movie)
            }
        }
        guard !pool.isEmpty else {
            return "Pass the titles that belong on it — pick them yourself."
        }
        var tvCount = 0
        for movie in pool where movie.mediaKind == "tv" { tvCount += 1 }
        await ChatAgentBridge.shared.step("wand.and.stars", "Building “\(trimmed)”")
        let listKind = tvCount > pool.count - tvCount ? "tv" : "movie"

        var list = await ChatAgentBridge.resolveList(named: trimmed)
        if list == nil {
            list = try? await SupabaseService.shared.createList(name: trimmed, mediaKind: listKind)
        }
        guard let list else { return "Couldn't create the list — connection trouble." }

        var added: [String] = []
        for movie in pool where movie.mediaKind == list.kind {
            do {
                try await SupabaseService.shared.cacheMovie(movie)
            } catch {
                SupabaseService.logSwallowed("curate_cache_movie", error)
            }
            if (try? await SupabaseService.shared.addToList(list.id, movieID: movie.tmdbID)) != nil {
                added.append(movie.title)
            }
        }
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        guard !added.isEmpty else {
            return "“\(list.name)” exists but none of those titles matched — try different ones."
        }
        await ChatAgentBridge.shared.note("list.star",
                                          "“\(list.name)” — \(added.count) titles",
                                          destination: .customList(list.id))
        let dropped = pool.count - added.count
        let droppedNote = dropped > 0
            ? " (\(dropped) skipped — wrong type for this \(list.kind == "tv" ? "TV" : "movie") list; tell them)"
            : ""
        return "Done — “\(list.name)” has \(added.joined(separator: ", ")).\(droppedNote)"
    }
}

@available(iOS 26.0, *)
struct AddToListTool: Tool {
    let name = "addMovieToList"
    let description = "Add a title to a custom list (created if missing). Only when they explicitly ask."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
        @Guide(description: "List name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard await ChatAgentBridge.shared.promptAsksToAdd else {
            return "STOP — they didn't ask to add anything to a list. Recommend only; they tap to add."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        var list = await ChatAgentBridge.resolveList(named: arguments.listName)
        if list == nil {
            // A new list inherits the title's kind — lists hold one type.
            // No receipt yet: only confirm once the title actually lands,
            // so a failed add can't leave a misleading "Created" chip.
            list = try? await SupabaseService.shared.createList(
                name: arguments.listName.trimmingCharacters(in: .whitespaces),
                mediaKind: movie.mediaKind)
        }
        guard let list else { return "Couldn't find or create that list." }
        if list.kind != movie.mediaKind {
            let listType = list.kind == "tv" ? "a TV show list" : "a movie list"
            let titleType = movie.mediaKind == "tv" ? "a show" : "a movie"
            return "“\(list.name)” is \(listType) and \(movie.title) is \(titleType) — lists hold one type. Offer to make a new list for it."
        }
        await ChatAgentBridge.shared.step("plus.circle", "Adding \(movie.title) to “\(list.name)”")
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
    let description = "Remove a title from a custom list."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
        @Guide(description: "List name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("minus.circle", "Updating the list")
        guard let list = await ChatAgentBridge.resolveList(named: arguments.listName) else {
            return "They don't have a list called \(arguments.listName)."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        do {
            try await SupabaseService.shared.removeFromList(list.id, movieID: movie.tmdbID)
        } catch {
            return "Couldn't remove \(movie.title) — connection trouble."
        }
        await ChatAgentBridge.shared.store?.refreshCustomLists()
        await ChatAgentBridge.shared.note("minus.circle", "\(movie.title) ✕ “\(list.name)”", destination: .customList(list.id))
        return "Removed \(movie.title) from “\(list.name)”."
    }
}

@available(iOS 26.0, *)
struct DeleteListTool: Tool {
    let name = "deleteList"
    let description = "Permanently delete a custom list. Only after explicit confirmation."

    @Generable
    struct Arguments {
        @Guide(description: "List name")
        var listName: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard await ChatAgentBridge.shared.promptConfirmsDestruction else {
            return "STOP — they didn't confirm a deletion. Ask 'Delete “\(arguments.listName)”? This can't be undone.' and wait for a yes."
        }
        guard let list = await ChatAgentBridge.resolveList(named: arguments.listName) else {
            return "They don't have a list called \(arguments.listName)."
        }
        await ChatAgentBridge.shared.step("trash", "Deleting “\(list.name)”")
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
    let description = "Find members by name or username."

    @Generable
    struct Arguments {
        @Guide(description: "Name or username")
        var query: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("magnifyingglass", "Searching members")
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
    let description = "Follow a member."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("person.badge.plus", "Following")
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        do {
            try await SupabaseService.shared.requestFollow(member.id)
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
    let description = "Unfollow a member."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("person.badge.minus", "Updating follows")
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        do {
            try await SupabaseService.shared.unfollow(member.id)
        } catch {
            return "Couldn't unfollow @\(member.username) — connection trouble."
        }
        await FriendsCache.shared.refresh()
        await ChatAgentBridge.shared.note("person.badge.minus", "Unfollowed @\(member.username)", destination: .member(member.id, member.username))
        return "Unfollowed @\(member.username)."
    }
}

@available(iOS 26.0, *)
struct SendRecTool: Tool {
    let name = "sendRecommendation"
    let description = "Send a title to a member they NAME. Never for where-to-watch (use lookupMovie)."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
        @Guide(description: "The title")
        var title: String
        @Guide(description: "Short note, or empty")
        var note: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("paperplane", "Sending the rec")
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
    let description = "Open the ranking flow for a title they've watched."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("arrow.up.arrow.down", "Opening the ranker")
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
    let description = "Delete the user's rating for a title. Only after explicit confirmation."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        guard await ChatAgentBridge.shared.promptConfirmsDestruction else {
            return "STOP — they didn't confirm. Ask 'Delete your \(arguments.title) rating?' and wait for a yes."
        }
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        guard await store.isWatched(movie.tmdbID) else {
            return "\(movie.title) isn't on their ranked list."
        }
        await ChatAgentBridge.shared.step("trash", "Deleting your \(movie.title) rating")
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
    let description = "The user's custom lists with counts."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("list.bullet", "Checking your lists")
        let lists = (try? await SupabaseService.shared.myLists()) ?? []
        guard !lists.isEmpty else { return "They have no custom lists yet — just the built-in Want to Watch." }
        return lists.map { "\($0.name) (\($0.count) titles)" }.joined(separator: "; ")
    }
}

@available(iOS 26.0, *)
struct RecommendTool: Tool {
    let name = "getRecommendations"
    let description = "Fresh titles the user has NOT seen, ranked by how much they'll like them. Use this for 'what should I watch' / 'recommend me something' — never recommend titles they've already ranked."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("sparkles", "Finding picks you haven't seen")
        let recs = (try? await SupabaseService.shared.recsForUser(limit: 8)) ?? []
        guard !recs.isEmpty else {
            return "No personalized recs yet (they need a few more rankings). Suggest ONE famous film in their favorite genres they likely haven't seen, grounded with lookupMovie."
        }
        let titles = await ChatAgentBridge.titles(for: recs.map(\.movieId))
        let lines = recs.compactMap { rec -> String? in
            guard let title = titles[rec.movieId] else { return nil }
            return "\(title) — predicted \(String(format: "%.1f", rec.recScore))/10"
        }
        return "Unseen picks they'll likely love (NOT watched yet — safe to recommend): "
            + lines.joined(separator: "; ")
            + ". Pick ONE, ground it with lookupMovie, and say why it fits their taste."
    }
}


@available(iOS 26.0, *)
struct FriendWatchedTool: Tool {
    let name = "getFriendRankings"
    let description = "A member's ranked titles with scores, best first."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("star", "Reading their rankings")
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
    let description = "A member's Want to Watch list."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("bookmark", "Reading their Want to Watch")
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
    let description = "Titles both watched (both scores) and both want to watch."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("person.2", "Finding your overlap")
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

@available(iOS 26.0, *)
struct RequestRecsTool: Tool {
    let name = "requestRecsFromFriend"
    let description = "Ask a friend (by username) for a rec, optionally narrowed by type/genre/note. They get a request to send you something."

    @Generable
    struct Arguments {
        @Guide(description: "Username to ask")
        var username: String
        @Guide(description: "movie or tv, or empty for either")
        var kind: String
        @Guide(description: "Genre to ask for, or empty")
        var genre: String
        @Guide(description: "Short note like 'for movie night', or empty")
        var note: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("hand.wave", "Asking your friend")
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        let kind = arguments.kind.lowercased()
        let mediaKind = (kind == "movie" || kind == "tv") ? kind : nil
        let genre = arguments.genre.trimmingCharacters(in: .whitespaces)
        let note = arguments.note.trimmingCharacters(in: .whitespaces)
        let sent = await SupabaseService.shared.requestRecs(
            to: [member.id], mediaKind: mediaKind,
            genre: genre.isEmpty ? nil : genre,
            decade: nil, maxRuntime: nil, streamingProvider: nil,
            note: note.isEmpty ? nil : note)
        guard sent > 0 else {
            return "Couldn't ask — you can only request from people you follow. Offer to follow @\(member.username) first."
        }
        await ChatAgentBridge.shared.note("hand.wave.fill", "Asked @\(member.username) for a rec", destination: .member(member.id, member.username))
        return "Asked @\(member.username) for a rec — it'll land in your Friend Recs when they send one."
    }
}

@available(iOS 26.0, *)
struct IncomingRecsTool: Tool {
    let name = "getRecsFriendsSentMe"
    let description = "Recs friends have sent the user (their Friend Recs inbox), with who and any note."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("tray.and.arrow.down", "Checking your Friend Recs")
        let recs = (try? await SupabaseService.shared.directRecs()) ?? []
        guard !recs.isEmpty else {
            return "No one's sent them a rec yet — they can ask a friend with requestRecsFromFriend."
        }
        var lines: [String] = []
        for rec in recs.prefix(10) {
            let who = rec.profiles?.username ?? "a friend"
            let title = rec.movies?.asMovie.title ?? "a title"
            let note = rec.note.map { " — “\($0)”" } ?? ""
            lines.append("@\(who): \(title)\(note)")
        }
        return "Friends recommended: " + lines.joined(separator: "; ")
    }
}

@available(iOS 26.0, *)
struct StreamingAlertTool: Tool {
    let name = "alertWhenStreaming"
    let description = "Turn on a notification for when a title becomes streamable. Only when they ask to be told/alerted."

    @Generable
    struct Arguments {
        @Guide(description: "The title")
        var title: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("bell", "Setting the alert")
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        if !movie.streamingOn.isEmpty {
            return "\(movie.title) is already streaming on \(movie.streamingOn.prefix(2).joined(separator: ", "))."
        }
        try? await SupabaseService.shared.cacheMovie(movie)
        let ok = await SupabaseService.shared.setStreamingAlert(movieID: movie.tmdbID, enabled: true)
        guard ok else { return "Couldn't set that alert — connection trouble." }
        await ChatAgentBridge.shared.note("bell.fill", "Alert on for \(movie.title)", destination: .movie(movie.tmdbID))
        return "Done — I'll notify them the moment \(movie.title) starts streaming."
    }
}

@available(iOS 26.0, *)
struct MarkWatchingTool: Tool {
    let name = "markCurrentlyWatching"
    let description = "Mark a TV show as currently watching at a season/episode they're on. Shows only — never movies."

    @Generable
    struct Arguments {
        @Guide(description: "The show title")
        var title: String
        @Guide(description: "Season number they're on")
        var season: Int
        @Guide(description: "Episode number they're on")
        var episode: Int
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("tv", "Updating Currently Watching")
        guard let movie = await ChatAgentBridge.resolveMovie(arguments.title) else {
            return "No title matched \"\(arguments.title)\"."
        }
        guard movie.mediaKind == "tv" else {
            return "\(movie.title) is a movie — only shows can be marked currently watching."
        }
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        let s = max(1, arguments.season), e = max(1, arguments.episode)
        try? await SupabaseService.shared.cacheMovie(movie)
        do {
            try await SupabaseService.shared.setShowProgress(showID: movie.tmdbID, season: s, episode: e)
            await store.watchlistSuperseded(movieID: movie.tmdbID)
        } catch {
            return "Couldn't save that — connection trouble."
        }
        await ChatAgentBridge.shared.note("tv.fill", "Watching \(movie.title) · S\(s)·E\(e)", destination: .movie(movie.tmdbID))
        return "Got it — \(movie.title) is on their Currently Watching at season \(s), episode \(e)."
    }
}

@available(iOS 26.0, *)
struct TasteMatchTool: Tool {
    let name = "getTasteMatch"
    let description = "How closely the user's taste matches a member's, as a percentage."

    @Generable
    struct Arguments {
        @Guide(description: "Username")
        var username: String
    }

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("heart.text.square", "Checking taste match")
        guard let member = await ChatAgentBridge.resolveMember(arguments.username) else {
            return "No member matched @\(arguments.username)."
        }
        guard let pct = await SupabaseService.shared.tasteMatch(with: member.id) else {
            return "No taste match with @\(member.username) yet — needs more overlap in what you've both ranked."
        }
        return "Their taste match with @\(member.username) is \(Int(pct))%."
    }
}

@available(iOS 26.0, *)
struct MyStatsTool: Tool {
    let name = "getMyStats"
    let description = "The user's own standing: global rank on Cini, ranking streak, and counts."

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        await ChatAgentBridge.shared.step("chart.bar", "Pulling your stats")
        guard let store = await ChatAgentBridge.shared.store else { return "The app isn't ready." }
        let watched = await store.watchedCount
        let watchlist = await store.watchlistCount
        var rankLine = ""
        if let me = SupabaseService.shared.currentUserID,
           let rank = try? await SupabaseService.shared.globalRank(userID: me) {
            rankLine = "#\(rank) on Cini. "
        }
        return "\(rankLine)\(watched) ranked, \(watchlist) on Want to Watch."
    }
}

#endif
