import StoreKit
import UIKit

/// Asking for an App Store review, done right: only at a genuine high point,
/// rarely, and never as a nag. We fire Apple's native star prompt right after a
/// milestone celebration (e.g. the 10th rank) — the user just saw confetti, so
/// they're as happy as they'll be. Apple throttles the prompt to a few times a
/// year on top of these guards, so we spend those shots on the happy moment.
@MainActor
enum ReviewPrompt {
    private static let askedCountKey = "review.askedCount"
    private static let lastAskedKey = "review.lastAskedAt"

    /// Never ask more than this many times, ever.
    private static let maxLifetimeAsks = 3
    /// And never twice inside this window.
    private static let minDaysBetween: Double = 90

    /// Call at a peak-delight moment. Silently does nothing if we've already
    /// asked recently or hit the lifetime cap, or if there's no active window.
    static func askAfterDelight() {
        let defaults = UserDefaults.standard

        let asked = defaults.integer(forKey: askedCountKey)
        guard asked < maxLifetimeAsks else { return }

        if let last = defaults.object(forKey: lastAskedKey) as? Date,
           Date().timeIntervalSince(last) < minDaysBetween * 86_400 {
            return
        }

        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }

        AppStore.requestReview(in: scene)

        // Count the attempt (Apple may or may not actually show it) so our own
        // cap holds regardless.
        defaults.set(asked + 1, forKey: askedCountKey)
        defaults.set(Date(), forKey: lastAskedKey)
    }
}
