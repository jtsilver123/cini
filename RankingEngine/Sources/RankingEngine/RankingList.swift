import Foundation

/// A user's fully-ordered ranked list, grouped into sentiment buckets.
/// Pure model — no UI, no persistence. The app layer mirrors mutations
/// to Supabase via the `rank_insert` / `rank_remove` RPCs.
public struct RankingList<ID: Hashable & Codable & Sendable>: Codable, Sendable {

    /// Bucket contents ordered best → worst.
    private var buckets: [Sentiment: [ID]]
    /// Sentiment lookup for membership checks and re-ranking.
    private var sentiments: [ID: Sentiment]

    public init() {
        buckets = [.loved: [], .fine: [], .disliked: []]
        sentiments = [:]
    }

    /// Rebuild a list from persisted state. `items` must be ordered
    /// best → worst within each sentiment.
    public init(items: [RankedItem<ID>]) {
        self.init()
        for item in items where sentiments[item.id] == nil {
            buckets[item.sentiment, default: []].append(item.id)
            sentiments[item.id] = item.sentiment
        }
    }

    // MARK: - Reading

    public var count: Int { sentiments.count }
    public var isEmpty: Bool { sentiments.isEmpty }

    public func contains(_ id: ID) -> Bool { sentiments[id] != nil }

    public func sentiment(of id: ID) -> Sentiment? { sentiments[id] }

    public func bucket(_ sentiment: Sentiment) -> [ID] { buckets[sentiment] ?? [] }

    /// Every item with derived rank and score, ordered best → worst.
    /// Scores are recomputed from positions on every read, so they are
    /// always consistent with the current order.
    public var scoredItems: [ScoredItem<ID>] {
        var result: [ScoredItem<ID>] = []
        result.reserveCapacity(count)
        var rank = 1
        for sentiment in Sentiment.displayOrder {
            let ids = buckets[sentiment] ?? []
            let scores = ScoreCalculator.scores(forBucketOf: ids.count, sentiment: sentiment)
            for (position, id) in ids.enumerated() {
                result.append(ScoredItem(
                    id: id,
                    sentiment: sentiment,
                    rank: rank,
                    bucketPosition: position,
                    score: scores[position]
                ))
                rank += 1
            }
        }
        return result
    }

    public func scoredItem(for id: ID) -> ScoredItem<ID>? {
        scoredItems.first { $0.id == id }
    }

    // MARK: - Inserting

    /// Begin ranking a new movie (or re-ranking an existing one — see
    /// `beginReranking`). Traps if the item is already in the list.
    /// `seedPosition` (predicted insertion index) and `similarity` (per-bucket-
    /// item genre overlap, aligned to `bucket(sentiment)`) are optional hints
    /// that make the head-to-head opponents relevant; nil falls back to a plain
    /// binary search.
    public func beginInsertion(of id: ID, sentiment: Sentiment,
                               seedPosition: Int? = nil,
                               similarity: [Double]? = nil) -> InsertionSession<ID> {
        precondition(sentiments[id] == nil, "Item already ranked; use beginReranking")
        return InsertionSession(newItemID: id, sentiment: sentiment, bucketIDs: bucket(sentiment),
                                seedPosition: seedPosition, similarity: similarity)
    }

    /// "Rank again": removes the existing entry and starts a fresh session
    /// (possibly into a different bucket). The entry is not present in the
    /// list while the session runs, so it can't be its own opponent.
    public mutating func beginReranking(of id: ID, sentiment: Sentiment,
                                        seedPosition: Int? = nil,
                                        similarity: [Double]? = nil) -> InsertionSession<ID> {
        remove(id)
        return beginInsertion(of: id, sentiment: sentiment,
                              seedPosition: seedPosition, similarity: similarity)
    }

    /// Commit a finished session. Returns the new item's scored entry.
    @discardableResult
    public mutating func commit(_ session: InsertionSession<ID>) -> ScoredItem<ID> {
        precondition(session.isComplete, "Session has unanswered comparisons")
        precondition(sentiments[session.newItemID] == nil, "Item already ranked")
        var ids = buckets[session.sentiment] ?? []
        // The bucket may have changed since the session snapshot (e.g. a
        // background sync); clamp so the commit is always valid.
        let position = min(session.resolvedBucketPosition!, ids.count)
        ids.insert(session.newItemID, at: position)
        buckets[session.sentiment] = ids
        sentiments[session.newItemID] = session.sentiment
        return scoredItem(for: session.newItemID)!
    }

    /// Convenience for the trivial cases (first movie ever, first movie in
    /// a bucket): begins and immediately commits a session if no
    /// comparisons are needed. Returns nil if comparisons are required.
    @discardableResult
    public mutating func insertWithoutComparisons(_ id: ID, sentiment: Sentiment) -> ScoredItem<ID>? {
        let session = beginInsertion(of: id, sentiment: sentiment)
        guard session.isComplete else { return nil }
        return commit(session)
    }

    // MARK: - Removing

    @discardableResult
    public mutating func remove(_ id: ID) -> Bool {
        guard let sentiment = sentiments.removeValue(forKey: id) else { return false }
        buckets[sentiment]?.removeAll { $0 == id }
        return true
    }
}
