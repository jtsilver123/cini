import StoreKit
import UIKit

/// Asking for an App Store review, done right: only at genuine high points,
/// and spent wisely. Apple shows the native star prompt at most ~3 times per
/// year, so we mirror that — a rolling budget of 3 attempts per 365 days, kept
/// at least ~90 days apart — and fire it from the app's best moments (a rank
/// milestone, a new streak high, a standout score). Whichever happy moment
/// comes first when the budget allows spends an attempt; the rest self-skip.
@MainActor
enum ReviewPrompt {
    private static let datesKey = "review.askDates"   // [Double] (epoch seconds)

    /// Apple's own ceiling — never attempt more than this in a rolling year.
    private static let maxPerYear = 3
    /// Spread the year's attempts out so they never cluster.
    private static let minDaysBetween: Double = 90
    private static let year: Double = 365 * 86_400
    private static let day: Double = 86_400

    /// Call at a peak-delight moment. Silently does nothing unless we're inside
    /// the rolling budget, far enough from the last ask, and have a live window.
    static func askAfterDelight() {
        let defaults = UserDefaults.standard
        let now = Date()

        var dates = (defaults.array(forKey: datesKey) as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
            .filter { now.timeIntervalSince($0) < year }   // drop anything over a year old

        // Budget: at most `maxPerYear` in the trailing 365 days.
        guard dates.count < maxPerYear else { persist(dates); return }
        // Spacing: never twice inside the minimum gap.
        if let last = dates.max(), now.timeIntervalSince(last) < minDaysBetween * day {
            persist(dates); return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { persist(dates); return }

        AppStore.requestReview(in: scene)

        // Count the attempt (Apple may or may not actually present it) so the
        // budget holds either way.
        dates.append(now)
        persist(dates)
    }

    private static func persist(_ dates: [Date]) {
        UserDefaults.standard.set(dates.map { $0.timeIntervalSince1970 }, forKey: datesKey)
    }
}
