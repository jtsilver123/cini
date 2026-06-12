import AppIntents
import Foundation

// Siri / Shortcuts / Spotlight actions. The new Siri (iOS 27) drives
// third-party apps through these same App Intents, so "add Dune to my
// watchlist in Cini" works hands-free; on iOS 17–26 classic Siri runs
// the identical intents and asks a follow-up for the title.

/// Shared title → Movie resolution for spoken queries: exact-title match
/// in the top results beats popularity noise, otherwise the first hit.
enum SiriTitleResolver {
    static func resolve(_ raw: String) async -> Movie? {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let results = (try? await TMDBService.shared.search(query: query, year: nil)) ?? []
        let lowered = query.lowercased()
        for movie in results.prefix(10) where movie.title.lowercased() == lowered {
            return movie
        }
        return results.first
    }

    static func spokenName(_ movie: Movie) -> String {
        movie.releaseYear.map { "\(movie.title) (\($0))" } ?? movie.title
    }
}

struct AddToWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to Want to Watch"
    static let description = IntentDescription(
        "Save a movie or TV show to your Want to Watch list.")

    @Parameter(title: "Movie or show", requestValueDialog: "Which movie or show?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$query) to Want to Watch")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let me = SupabaseService.shared.currentUserID else {
            return .result(dialog: "Open Cini and sign in first — then I can save titles for you.")
        }
        guard let movie = await SiriTitleResolver.resolve(query) else {
            return .result(dialog: "I couldn't find anything called “\(query)”.")
        }
        let name = SiriTitleResolver.spokenName(movie)
        let current = (try? await SupabaseService.shared.watchlist(userID: me)) ?? []
        if current.contains(where: { $0.movieId == movie.tmdbID }) {
            return .result(dialog: "\(name) is already on your Want to Watch.")
        }
        try await SupabaseService.shared.cacheMovie(movie)
        try await SupabaseService.shared.watchlistToggle(movieID: movie.tmdbID)
        return .result(dialog: "Saved — \(name) is on your Want to Watch.")
    }
}

struct RemoveFromWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "Remove from Want to Watch"
    static let description = IntentDescription(
        "Take a movie or TV show off your Want to Watch list.")

    @Parameter(title: "Movie or show", requestValueDialog: "Which movie or show?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Remove \(\.$query) from Want to Watch")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let me = SupabaseService.shared.currentUserID else {
            return .result(dialog: "Open Cini and sign in first — then I can manage your lists.")
        }
        let current = (try? await SupabaseService.shared.watchlist(userID: me)) ?? []
        guard !current.isEmpty else {
            return .result(dialog: "Your Want to Watch is empty.")
        }
        // Match against what's actually on the list — no TMDB round-trip,
        // and "dune" can't remove the wrong Dune.
        let rows = (try? await SupabaseService.shared.movies(ids: current.map(\.movieId))) ?? []
        let lowered = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var match: Movie?
        for row in rows {
            let movie = row.asMovie
            if movie.title.lowercased() == lowered { match = movie; break }
            if match == nil, movie.title.lowercased().contains(lowered) { match = movie }
        }
        guard let match else {
            return .result(dialog: "“\(query)” isn't on your Want to Watch.")
        }
        try await SupabaseService.shared.watchlistToggle(movieID: match.tmdbID)
        return .result(dialog: "Done — \(SiriTitleResolver.spokenName(match)) is off your Want to Watch.")
    }
}

struct WhatsOnWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "What's on my Want to Watch"
    static let description = IntentDescription(
        "Hear the latest titles on your Want to Watch list.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let me = SupabaseService.shared.currentUserID else {
            return .result(dialog: "Open Cini and sign in first — then I can read your list.")
        }
        let current = (try? await SupabaseService.shared.watchlist(userID: me)) ?? []
        guard !current.isEmpty else {
            return .result(dialog: "Your Want to Watch is empty — say “add a movie in Cini” to start it.")
        }
        let rows = (try? await SupabaseService.shared.movies(ids: current.map(\.movieId))) ?? []
        let titleByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.tmdbId, $0.asMovie.title) })
        // Watchlist rows arrive newest first; keep that order.
        let titles = current.compactMap { titleByID[$0.movieId] }.prefix(5)
        let spoken = titles.joined(separator: ", ")
        let more = current.count > 5 ? ", and \(current.count - 5) more" : ""
        return .result(dialog: "You have \(current.count) saved. Up top: \(spoken)\(more).")
    }
}

struct OpenMovieIntent: AppIntent {
    static let title: LocalizedStringResource = "Show a movie or show"
    static let description = IntentDescription(
        "Open a movie or TV show's page in Cini.")
    static let openAppWhenRun: Bool = true

    @Parameter(title: "Movie or show", requestValueDialog: "Which movie or show?")
    var query: String

    static var parameterSummary: some ParameterSummary {
        Summary("Show \(\.$query) in Cini")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let movie = await SiriTitleResolver.resolve(query) else {
            return .result(dialog: "I couldn't find anything called “\(query)”.")
        }
        // Same deep-link plumbing a push notification tap uses.
        TabRouter.shared.pendingPushMovieID = movie.tmdbID
        TabRouter.shared.selection = .feed
        return .result(dialog: "Here's \(SiriTitleResolver.spokenName(movie)).")
    }
}

struct OpenWatchlistIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Want to Watch"
    static let description = IntentDescription(
        "Open your Want to Watch list in Cini.")
    static let openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult {
        TabRouter.shared.pendingListsTab = .watchlist
        TabRouter.shared.selection = .lists
        return .result()
    }
}

/// The phrases Siri listens for without any setup. Parameters aren't
/// embeddable in phrases for plain string types, so Siri follows up with
/// "Which movie or show?" — and the new Siri (iOS 27) fills them from
/// natural speech on its own.
struct CiniShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        // People rarely say "watchlist" — cover "my list" and "watch
        // later" phrasings too.
        AppShortcut(
            intent: AddToWatchlistIntent(),
            phrases: [
                "Add a movie in \(.applicationName)",
                "Add a movie to my watchlist in \(.applicationName)",
                "Add a show to my watchlist in \(.applicationName)",
                "Add a movie to my list in \(.applicationName)",
                "Add a show to my list in \(.applicationName)",
                "Add a movie to my lists in \(.applicationName)",
                "Save a movie in \(.applicationName)",
                "Save a movie to watch later in \(.applicationName)",
                "Save a show to watch later in \(.applicationName)",
                "I want to watch a movie later in \(.applicationName)",
                "Watch a movie later in \(.applicationName)",
                "Add to my Want to Watch in \(.applicationName)",
            ],
            shortTitle: "Add to Want to Watch",
            systemImageName: "bookmark"
        )
        AppShortcut(
            intent: WhatsOnWatchlistIntent(),
            phrases: [
                "What's on my watchlist in \(.applicationName)",
                "What's on my list in \(.applicationName)",
                "What should I watch in \(.applicationName)",
                "What do I want to watch in \(.applicationName)",
                "Read my Want to Watch in \(.applicationName)",
            ],
            shortTitle: "What's saved",
            systemImageName: "list.bullet"
        )
        AppShortcut(
            intent: OpenWatchlistIntent(),
            phrases: [
                "Open my watchlist in \(.applicationName)",
                "Open my Want to Watch in \(.applicationName)",
                "Open my list in \(.applicationName)",
                "Open my lists in \(.applicationName)",
                "Show my watch later list in \(.applicationName)",
            ],
            shortTitle: "Open Want to Watch",
            systemImageName: "bookmark.fill"
        )
        AppShortcut(
            intent: OpenMovieIntent(),
            phrases: [
                "Show a movie in \(.applicationName)",
                "Look up a show in \(.applicationName)",
            ],
            shortTitle: "Look up a title",
            systemImageName: "magnifyingglass"
        )
    }
}
