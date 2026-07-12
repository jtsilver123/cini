import Foundation
import Observation

/// Warm cache of the user's viewing preferences (streaming services +
/// preferred theater screens) so the surfaces that honor them — Tonight's
/// Pick, Where to Watch, the showtimes sheet — read them instantly instead
/// of each fetching. Warmed at sign-in (like FriendsCache), refreshed by
/// the settings screen after every save, cleared on sign-out.
@Observable
@MainActor
final class PrefsCache {
    static let shared = PrefsCache()

    private(set) var prefs = SupabaseService.ViewingPrefs()

    /// Canonical service names for O(1) "is this one of mine" checks.
    var services: Set<String> { Set(prefs.streamingServices) }
    var screenFormats: [String] { prefs.screenFormats }

    @ObservationIgnored private var warmTask: Task<Void, Never>?

    /// Fire-and-forget background load; concurrent calls coalesce.
    func warm() {
        guard warmTask == nil else { return }
        warmTask = Task {
            await refresh()
            warmTask = nil
        }
    }

    func refresh() async {
        if let fresh = try? await SupabaseService.shared.viewingPrefs() {
            prefs = fresh
        }
    }

    /// The settings screen pushes its saved value straight in, so every
    /// surface updates without waiting for a refetch.
    func apply(_ fresh: SupabaseService.ViewingPrefs) {
        prefs = fresh
    }

    /// Wipe on sign-out — the next account must not inherit these.
    func clear() {
        warmTask?.cancel()
        warmTask = nil
        prefs = SupabaseService.ViewingPrefs()
    }
}
