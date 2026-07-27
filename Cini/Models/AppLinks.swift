import Foundation

/// Canonical outward-facing links. The App Store URL is what we want people to
/// land on when something is shared; invite links carry the inviter's handle
/// (the `/i/` page redirects to the App Store while preserving the referral).
enum AppLinks {
    static let appStore = "https://apps.apple.com/us/app/cini-rank-every-film/id6778975898"

    /// Personalized invite link — opens the app for installed users (the page
    /// deep-links `cini://invite?u=`) and sends everyone else to the App Store.
    static func invite(_ username: String) -> String {
        "https://trycini.com/i/?u=\(username.urlQueryValueEncoded)"
    }

    /// Link to a specific list — opens that list in the app (the `/l/` page
    /// deep-links `cini://list?id=`) and sends everyone else to the App Store.
    static func listLink(_ id: UUID) -> String {
        "https://trycini.com/l/?id=\(id.uuidString.lowercased())"
    }

    /// Link to a member's public profile. Renders their rankings on the web
    /// (/u/?u=) for anyone; opens the profile in the app for installed users.
    static func profileLink(_ username: String) -> String {
        "https://trycini.com/u/?u=\(username.urlQueryValueEncoded)"
    }

    /// Link to a title's page — Cini's community score + metadata on the web
    /// (/m/?id=); opens the title in the app for installed users.
    static func titleLink(_ tmdbID: Int) -> String {
        "https://trycini.com/m/?id=\(tmdbID)"
    }

    /// A movie-night invite for someone who may not have Cini: the /night/
    /// page shows the title, the proposed time, and who's asking — then sends
    /// them to the App Store (or deep-links installed users to the title).
    static func nightLink(tmdbID: Int, at date: Date?, from username: String?) -> String {
        var link = "https://trycini.com/night/?m=\(tmdbID)"
        if let date { link += "&t=\(Int(date.timeIntervalSince1970))" }
        if let username, !username.isEmpty { link += "&f=\(username.urlQueryValueEncoded)" }
        return link
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
