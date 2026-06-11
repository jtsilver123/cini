import Foundation

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
