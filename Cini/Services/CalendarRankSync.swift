import EventKit
import UserNotifications
import UIKit

/// Calendar sync: with the user's permission, reads upcoming calendar events,
/// spots titles from their Want to Watch in them ("Dune with Sarah",
/// "Movie night: Oppenheimer"), and schedules a LOCAL "How was it? Rank it"
/// reminder for shortly after the event ends — the moment ranking is easiest.
///
/// Everything is on-device: EventKit read + UNUserNotificationCenter. No
/// calendar data is ever uploaded. The reminder carries kind/movie_id in its
/// userInfo, so tapping it routes through the normal push router straight to
/// the title's page.
///
/// Cini's OWN movie-night events (titles starting "🎬 ", written by
/// PlanWatchSheet's Add to Calendar) are skipped — the server's post-watch
/// nudge already covers those plans, and a double ping reads as a bug.
@MainActor
enum CalendarRankSync {
    static let enabledKey = "cal.rankRemindersOn"
    private static let lastScanKey = "cal.lastScanAt"
    private static let notifPrefix = "calrank-"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    static var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Ask for read (full) access — distinct from the write-only grant the
    /// plan sheet's Add to Calendar uses.
    static func requestAccess() async -> Bool {
        let store = EKEventStore()
        return (try? await store.requestFullAccessToEvents()) ?? false
    }

    /// Foreground hook: rescan at most every 6 hours (a calendar rarely
    /// changes faster, and each scan reschedules everything it finds anyway).
    static func rescanIfDue(store: RankingStore) async {
        guard isEnabled, hasAccess else { return }
        let last = UserDefaults.standard.double(forKey: lastScanKey)
        guard Date().timeIntervalSince1970 - last > 6 * 3600 else { return }
        await rescan(store: store)
    }

    /// Full scan: next 7 days of events → match → (re)schedule reminders.
    /// Also prunes reminders for titles ranked since the last scan.
    static func rescan(store: RankingStore) async {
        guard isEnabled, hasAccess else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastScanKey)

        // Candidates: unranked Want to Watch titles, tokenized once.
        var candidates: [(id: Int, tokens: [String], title: String)] = []
        for item in store.watchlist where !store.isWatched(item.movieID) {
            guard let movie = store.movie(item.movieID) else { continue }
            let toks = Self.tokens(movie.title)
            guard !toks.isEmpty else { continue }
            candidates.append((item.movieID, toks, movie.title))
        }

        // EventKit work off the main actor; EKEvent isn't Sendable, so only
        // plain values cross back.
        struct SlimEvent: Sendable {
            let id: String
            let title: String
            let end: Date
        }
        let events: [SlimEvent] = await Task.detached(priority: .utility) {
            let ek = EKEventStore()
            let start = Date()
            guard let end = Calendar.current.date(byAdding: .day, value: 7, to: start) else { return [] }
            let predicate = ek.predicateForEvents(withStart: start, end: end, calendars: nil)
            return ek.events(matching: predicate).compactMap { event in
                guard !event.isAllDay,
                      let title = event.title, !title.isEmpty,
                      // Cini's own movie-night events: the server nudges those.
                      !title.hasPrefix("🎬"),
                      let endDate = event.endDate,
                      endDate > Date(),
                      // A "movie" spanning >6h is a trip, not a screening.
                      endDate.timeIntervalSince(event.startDate) <= 6 * 3600,
                      let id = event.eventIdentifier else { return nil }
                return SlimEvent(id: id, title: title, end: endDate)
            }
        }.value

        let center = UNUserNotificationCenter.current()

        // Prune: any pending calendar reminder whose title has been ranked
        // (or fell off the watchlist) since it was scheduled.
        let liveIDs = Set(candidates.map(\.id))
        let pending = await center.pendingNotificationRequests()
            .filter { $0.identifier.hasPrefix(notifPrefix) }
        let stale = pending.filter { request in
            guard let movieID = request.content.userInfo["movie_id"] as? Int else { return true }
            return !liveIDs.contains(movieID)
        }
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: stale.map(\.identifier))
        }

        for event in events {
            let eventTokens = Self.tokens(event.title)
            guard let match = candidates.first(where: {
                Self.matches(movieTokens: $0.tokens, eventTokens: eventTokens)
            }) else { continue }
            schedule(movieID: match.id, movieTitle: match.title,
                     eventID: event.id,
                     // ~30 min after the credits, while it's fresh.
                     fireAt: event.end.addingTimeInterval(30 * 60),
                     center: center)
        }
    }

    /// A title just got ranked — its "rank it" reminder is now noise.
    /// (The periodic rescan would catch this too, but a movie ranked at the
    /// theater should kill tonight's reminder immediately.)
    static func movieRanked(_ movieID: Int) {
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.pendingNotificationRequests()
                .filter { $0.identifier.hasPrefix(notifPrefix)
                       && ($0.content.userInfo["movie_id"] as? Int) == movieID }
                .map(\.identifier)
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    /// Toggle off / sign-out: cancel every calendar reminder.
    static func clearScheduled() {
        let center = UNUserNotificationCenter.current()
        Task {
            let ids = await center.pendingNotificationRequests()
                .map(\.identifier)
                .filter { $0.hasPrefix(notifPrefix) }
            if !ids.isEmpty { center.removePendingNotificationRequests(withIdentifiers: ids) }
        }
    }

    // MARK: - Matching

    /// Lowercased word tokens, punctuation stripped — "Dune: Part Two" →
    /// ["dune", "part", "two"].
    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    /// Words that mark an event as movie-shaped — required before a ONE-word
    /// title may match, so "Heat" pings for "Watch Heat" but never for
    /// "Heating repair" or a contact named Heather.
    private static let filmSignals: Set<String> = [
        "movie", "movies", "film", "cinema", "theater", "theatre", "watch",
        "watching", "screening", "showing", "amc", "imax", "regal", "🍿",
    ]

    /// The movie's tokens must appear CONSECUTIVELY in the event's tokens
    /// (word boundaries, order preserved). One-word titles additionally need
    /// a film-signal word somewhere in the event, or to BE the whole event.
    private static func matches(movieTokens: [String], eventTokens: [String]) -> Bool {
        guard !movieTokens.isEmpty, movieTokens.count <= eventTokens.count else { return false }
        let found = (0...(eventTokens.count - movieTokens.count)).contains { start in
            Array(eventTokens[start..<(start + movieTokens.count)]) == movieTokens
        }
        guard found else { return false }
        if movieTokens.count == 1 {
            return eventTokens == movieTokens
                || eventTokens.contains(where: { filmSignals.contains($0) })
        }
        return true
    }

    // MARK: - Scheduling

    private static func schedule(movieID: Int, movieTitle: String, eventID: String,
                                 fireAt: Date, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = "Cini"
        content.body = "How was \(movieTitle)? Rank it — takes 20 seconds 🎬"
        content.sound = .default
        // Rides the same keys as a server push, so the existing tap routing
        // opens the movie page with no new cases.
        content.userInfo = ["kind": "post_watch_nudge", "movie_id": movieID]

        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: fireAt)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        // Keyed by event id: a rescan (or a rescheduled event) replaces the
        // old reminder instead of stacking a second one.
        let request = UNNotificationRequest(identifier: notifPrefix + eventID,
                                            content: content, trigger: trigger)
        center.add(request)
    }
}
