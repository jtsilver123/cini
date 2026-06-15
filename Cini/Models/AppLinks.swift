import Foundation

/// Canonical outward-facing links. The App Store URL is what we want people to
/// land on when something is shared; invite links carry the inviter's handle
/// (the `/i/` page redirects to the App Store while preserving the referral).
enum AppLinks {
    static let appStore = "https://apps.apple.com/us/app/cini-rank-every-film/id6778975898"

    /// Personalized invite link — opens the app for installed users (the page
    /// deep-links `cini://invite?u=`) and sends everyone else to the App Store.
    static func invite(_ username: String) -> String {
        "https://jtsilver123.github.io/cini/i/?u=\(username)"
    }
}
