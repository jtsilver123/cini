import Foundation
import Observation

/// Warm cache of the social data quick interactions need instantly:
/// who you follow and how often you've tagged each friend as "watched
/// with". Warmed in the background at sign-in and after each log, so the
/// log flow's chips and the Recommend sheet render with zero wait instead
/// of after a network round-trip.
@Observable
@MainActor
final class FriendsCache {
    static let shared = FriendsCache()

    private(set) var following: [ProfileRow] = []
    private(set) var watchedWithCounts: [UUID: Int] = [:]
    private var lastRefreshed: Date?

    /// Friends ordered by how often they get tagged — the order every
    /// picker should use.
    var byTagFrequency: [ProfileRow] {
        following.sorted {
            let a = watchedWithCounts[$0.id] ?? 0, b = watchedWithCounts[$1.id] ?? 0
            return a == b ? $0.username < $1.username : a > b
        }
    }

    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// Fire-and-forget background refresh. Concurrent calls coalesce —
    /// sign-in and the first log both warm within seconds of each other.
    func warm() {
        guard warmTask == nil else { return }
        warmTask = Task {
            await refresh()
            warmTask = nil
        }
    }

    /// Refresh only when the cache is older than 5 minutes — views call
    /// this on appear and render the cached data immediately.
    func refreshIfStale() {
        let stale = lastRefreshed.map { Date().timeIntervalSince($0) > 300 } ?? true
        if stale { warm() }
    }

    func refresh() async {
        if let fresh = try? await SupabaseService.shared.following() {
            following = fresh
            // Only a successful fetch counts as "refreshed" — stamping a
            // failure would make refreshIfStale sit on bad data for 5 minutes.
            lastRefreshed = Date()
        }
        watchedWithCounts = await SupabaseService.shared.watchedWithCounts()
    }

    /// Wipe on sign-out so the next account never sees the previous account's
    /// friends in the log-flow chips, @-mention picker, or Recommend sheet.
    func clear() {
        warmTask?.cancel()
        warmTask = nil
        following = []
        watchedWithCounts = [:]
        lastRefreshed = nil
    }
}
