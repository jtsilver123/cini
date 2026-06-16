import Foundation

/// Canonical outward-facing links. The App Store URL is what we want people to
/// land on when something is shared; invite links carry the inviter's handle
/// (the `/i/` page redirects to the App Store while preserving the referral).
enum AppLinks {
    static let appStore = "https://apps.apple.com/us/app/cini-rank-every-film/id6778975898"

    /// Personalized invite link — opens the app for installed users (the page
    /// deep-links `cini://invite?u=`) and sends everyone else to the App Store.
    static func invite(_ username: String) -> String {
        "https://trycini.com/i/?u=\(username)"
    }

    /// Link to a specific list — opens that list in the app (the `/l/` page
    /// deep-links `cini://list?id=`) and sends everyone else to the App Store.
    static func listLink(_ id: UUID) -> String {
        "https://trycini.com/l/?id=\(id.uuidString.lowercased())"
    }
}

extension String {
    /// Percent-encode for use as a URL query VALUE. `.urlQueryAllowed` leaves
    /// the sub-delimiters "&?=+;/" intact, so a value containing "&" (an SMS
    /// invite body, or a title like "Fast & Furious") gets truncated at the
    /// "&". Removing them from the allowed set escapes them properly.
    var urlQueryValueEncoded: String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&?=+;/")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
