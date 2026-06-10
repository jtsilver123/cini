import Foundation

/// Build-time configuration. Values come from Resources/Secrets.xcconfig
/// (git-ignored) via Info.plist substitution; see README for setup.
enum AppConfig {
    static var tmdbAPIKey: String { value(for: "TMDB_API_KEY") }
    static var supabaseURL: URL { URL(string: value(for: "SUPABASE_URL"))! }
    static var supabaseAnonKey: String { value(for: "SUPABASE_ANON_KEY") }

    /// MovieGlu (or compatible) showtimes API credentials. Optional —
    /// the Showtimes UI degrades to a "coming soon" state without them.
    static var showtimesAPIKey: String? { optionalValue(for: "MOVIEGLU_API_KEY") }
    static var showtimesAuthorization: String? { optionalValue(for: "MOVIEGLU_AUTHORIZATION") }

    private static func value(for key: String) -> String {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String, !value.isEmpty else {
            fatalError("Missing \(key) — copy Secrets.example.xcconfig to Secrets.xcconfig and fill it in")
        }
        return value
    }

    private static func optionalValue(for key: String) -> String? {
        let value = Bundle.main.object(forInfoDictionaryKey: key) as? String
        return (value?.isEmpty ?? true) ? nil : value
    }
}
