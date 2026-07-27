import Foundation

extension DateFormatter {
    /// Locale-safe "yyyy-MM-dd" pinned to UTC. Use ONLY when a fixed zone is
    /// what you want (stable sort keys); for anything a user sees or picks,
    /// use `localDay` below.
    static let posixDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// "yyyy-MM-dd" in the DEVICE's timezone — the app's convention for
    /// date-only values (watch_date / watched_on / release days): store the
    /// calendar day the user actually lived, and parse a stored day into a
    /// Date that local-calendar UI (DatePicker, `.formatted()`) renders as
    /// that same literal day. A UTC formatter here shifted evening logs and
    /// imported Letterboxd diaries a day off for every US user.
    static let localDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = .current
        return f
    }()
}

extension Date {
    /// Today's LOCAL-calendar day ordinal — the app's unit for "same day?"
    /// comparisons (Tonight's Pick recency, watching-story expiry). It must
    /// roll over at local midnight: the UTC arithmetic this replaced flipped
    /// at 5-8pm US time, so an evening's picks read as "shown today" all of
    /// the next morning.
    static var localDayOrdinal: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }
}

/// Typo-tolerant string matching for search: normalized edit distance with
/// adjacent-transposition support ("teh" → "the"), measured against both
/// the whole candidate and its typing prefix so partial queries score well.
enum Fuzzy {

    /// 0…1 — how well `query` matches `candidate` (1 = exact).
    static func similarity(query: String, candidate: String) -> Double {
        let q = Array(normalize(query))
        let full = Array(normalize(candidate))
        guard !q.isEmpty, !full.isEmpty else { return 0 }

        let wholeDistance = editDistance(q, full)
        let whole = 1 - Double(wholeDistance) / Double(max(q.count, full.count))

        // Mid-typing: compare against the candidate's prefix of equal length.
        let prefix = Array(full.prefix(q.count))
        let prefixDistance = editDistance(q, prefix)
        let typing = 1 - Double(prefixDistance) / Double(q.count)

        // Whole-title matches edge out prefix matches of equal quality.
        return max(whole, typing * 0.95)
    }

    private static func normalize(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// Damerau-Levenshtein (optimal string alignment variant).
    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous2 = [Int](repeating: 0, count: b.count + 1)
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    current[j] = min(current[j], previous2[j - 2] + 1)
                }
            }
            (previous2, previous, current) = (previous, current, previous2)
        }
        return previous[b.count]
    }
}
