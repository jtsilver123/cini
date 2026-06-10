import Foundation

/// The three-way sentiment a user picks before pairwise ranking begins.
/// Buckets are totally ordered: every `.loved` title outranks every `.fine`
/// title, which outranks every `.disliked` title.
public enum Sentiment: String, Codable, CaseIterable, Sendable, Hashable {
    case loved
    case fine
    case disliked

    /// The 0–10 score band that ranks in this bucket map into.
    public var scoreRange: ClosedRange<Double> {
        switch self {
        case .loved:    return 6.7...10.0
        case .fine:     return 3.4...6.6
        case .disliked: return 0.0...3.3
        }
    }

    /// Buckets in display order, best first.
    public static let displayOrder: [Sentiment] = [.loved, .fine, .disliked]

    /// Sort key: lower comes first in the global list.
    var orderIndex: Int {
        switch self {
        case .loved:    return 0
        case .fine:     return 1
        case .disliked: return 2
        }
    }
}
