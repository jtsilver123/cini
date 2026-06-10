import Foundation

/// One entry in a user's ranked list. Generic over the item identifier so the
/// engine has no knowledge of movies, TMDB, or persistence.
public struct RankedItem<ID: Hashable & Codable & Sendable>: Codable, Hashable, Sendable {
    public let id: ID
    public var sentiment: Sentiment

    public init(id: ID, sentiment: Sentiment) {
        self.id = id
        self.sentiment = sentiment
    }
}

/// A ranked entry decorated with its derived global position and score.
public struct ScoredItem<ID: Hashable & Codable & Sendable>: Codable, Hashable, Sendable {
    public let id: ID
    public let sentiment: Sentiment
    /// 1-based position in the user's full list (1 = best).
    public let rank: Int
    /// 0-based position within the sentiment bucket.
    public let bucketPosition: Int
    /// Derived 0–10 score, rounded to one decimal place.
    public let score: Double

    public init(id: ID, sentiment: Sentiment, rank: Int, bucketPosition: Int, score: Double) {
        self.id = id
        self.sentiment = sentiment
        self.rank = rank
        self.bucketPosition = bucketPosition
        self.score = score
    }
}
