import Foundation

/// The user's answer to one head-to-head comparison.
public enum ComparisonChoice: Sendable {
    /// The user preferred the movie being inserted.
    case preferNew
    /// The user preferred the existing, already-ranked movie.
    case preferExisting
    /// "Too tough to call" — ends the session, placing the new movie
    /// immediately below the movie it was just compared against.
    case tooToughToCall
    /// "Skip" — keep the insertion range but swap in a different opponent.
    /// When every candidate in the range has been skipped (or only one
    /// exists), falls back to placing adjacent like `tooToughToCall`.
    case skip
}

/// A binary-search insertion in progress. Pure value-type state machine:
/// feed it choices, read out the next comparison, and when `isComplete`
/// commit the `resolvedBucketPosition` back into the `RankingList`.
///
/// The candidate range `[low, high]` is the set of possible insertion
/// indices within the bucket (0 = best, bucketCount = worst). Each answer
/// halves the range, so insertion takes ~log₂(n) comparisons.
public struct InsertionSession<ID: Hashable & Codable & Sendable>: Sendable {
    public let newItemID: ID
    public let sentiment: Sentiment

    /// Bucket-local IDs ordered best → worst, snapshotted at session start.
    let bucketIDs: [ID]

    /// Optional predicted-score seed: the insertion index the new item is
    /// predicted to land at. Biases the FIRST comparison so the opponent is a
    /// title the user would likely score similarly — and it varies per title, so
    /// you stop seeing the same median movie every time.
    let seedPosition: Int?
    /// Optional per-bucket-item similarity to the new item (0…1, aligned to
    /// `bucketIDs`). Opponents skew toward the most-similar candidate near the
    /// search pivot, so head-to-heads compare like with like.
    let similarity: [Double]?

    private(set) var low: Int
    private(set) var high: Int
    private(set) var skipOffset: Int = 0
    /// Bucket indices already shown in the current `[low, high)` range.
    /// "Skip" must never re-show one of these — a dominant similarity score
    /// (or a seed/rotation collision) would otherwise repeat the same
    /// opponent. Cleared when the range narrows, together with `skipOffset`.
    private(set) var shownIndices: [Int] = []
    public private(set) var comparisonsMade: Int = 0
    public private(set) var resolvedBucketPosition: Int?

    /// Snapshots for Undo, pushed before every accepted choice.
    private var history: [Snapshot] = []

    private struct Snapshot: Sendable {
        let low: Int
        let high: Int
        let skipOffset: Int
        let shownIndices: [Int]
        let comparisonsMade: Int
        let resolvedBucketPosition: Int?
    }

    init(newItemID: ID, sentiment: Sentiment, bucketIDs: [ID],
         seedPosition: Int? = nil, similarity: [Double]? = nil) {
        self.newItemID = newItemID
        self.sentiment = sentiment
        self.bucketIDs = bucketIDs
        self.seedPosition = seedPosition
        // Only trust a similarity array that lines up with the bucket.
        self.similarity = (similarity?.count == bucketIDs.count) ? similarity : nil
        self.low = 0
        self.high = bucketIDs.count
        if bucketIDs.isEmpty {
            // First movie in this bucket — no comparisons needed.
            resolvedBucketPosition = 0
        }
    }

    public var isComplete: Bool { resolvedBucketPosition != nil }

    /// Whether there is a choice to undo.
    public var canUndo: Bool { !history.isEmpty }

    /// Bucket-local index of the existing item the user should be shown next.
    /// The midpoint of the candidate range, rotated by skips so "Skip" shows
    /// a different opponent without giving up any search progress.
    var comparisonIndex: Int? {
        guard !isComplete else { return nil }
        let span = high - low
        // Never modulo by zero: a zero-width span means there's nothing left to
        // compare (the position is resolved), so there's no opponent to show.
        guard span > 0 else { return nil }
        // Base pivot: on the very first comparison, start from the predicted-score
        // seed (so the opponent is a title you'd score similarly); otherwise the
        // binary-search midpoint. Skips rotate the pivot either way.
        let base: Int
        if comparisonsMade == 0, skipOffset == 0, let seed = seedPosition {
            base = min(max(seed, low), high - 1)
        } else {
            base = low + ((span / 2) + skipOffset) % span
        }
        // Bias toward the most-similar opponent within a small window around the
        // base, so head-to-heads compare like with like. The window is CAPPED at a
        // few positions so the pivot stays near the median — that keeps the search
        // ~log(n) (fewest taps) instead of letting an off-center pick balloon the
        // comparison count. No similarity → the plain midpoint.
        // Indices already shown in this range are excluded so "Skip" always
        // produces a fresh opponent (a dominant similarity score — or a seed
        // that collides with the rotation — would otherwise repeat one).
        let shown = Set(shownIndices)
        var pick = base
        if let similarity {
            let window = Swift.min(Swift.max(1, span / 4), 3)
            let lo = Swift.max(low, base - window)
            let hi = Swift.min(high - 1, base + window)
            var best = -1
            var bestSim = -1.0
            for i in lo...hi where !shown.contains(i) {
                let sim = similarity[i]
                // Highest similarity wins; on a tie pick the candidate closest to
                // the base so the search stays balanced (and opponents don't skew).
                if sim > bestSim || (sim == bestSim && best >= 0 && abs(i - base) < abs(best - base)) {
                    bestSim = sim
                    best = i
                }
            }
            if best >= 0 { pick = best }
        }
        // Rotation/seed can still land on an already-shown index — walk outward
        // to the nearest fresh one. (Skips are capped below span, so a fresh
        // index always exists in the range.)
        if shown.contains(pick) {
            var delta = 1
            while delta <= span {
                if pick - delta >= low, !shown.contains(pick - delta) { return pick - delta }
                if pick + delta < high, !shown.contains(pick + delta) { return pick + delta }
                delta += 1
            }
        }
        return pick
    }

    /// The existing movie to show head-to-head against the new one,
    /// or nil when the session is complete.
    public var currentOpponent: ID? {
        comparisonIndex.map { bucketIDs[$0] }
    }

    /// Upper bound on comparisons for this session, for progress UI.
    public var expectedComparisons: Int {
        bucketIDs.isEmpty ? 0 : Int(ceil(log2(Double(bucketIDs.count + 1))))
    }

    /// Approximate progress in 0...1 for progress dots.
    public var progress: Double {
        guard expectedComparisons > 0 else { return 1 }
        if isComplete { return 1 }
        return min(1, Double(comparisonsMade) / Double(expectedComparisons))
    }

    /// Apply the user's answer to the current comparison.
    public mutating func choose(_ choice: ComparisonChoice) {
        guard let mid = comparisonIndex else { return }
        history.append(Snapshot(low: low, high: high, skipOffset: skipOffset,
                                shownIndices: shownIndices,
                                comparisonsMade: comparisonsMade,
                                resolvedBucketPosition: resolvedBucketPosition))
        switch choice {
        case .preferNew:
            comparisonsMade += 1
            high = mid
        case .preferExisting:
            comparisonsMade += 1
            low = mid + 1
        case .tooToughToCall:
            // Place adjacent to (immediately below) the compared title.
            resolvedBucketPosition = mid + 1
            return
        case .skip:
            let span = high - low
            if span <= 1 || skipOffset + 1 >= span {
                // Nothing different left to show — place adjacent.
                resolvedBucketPosition = mid + 1
            } else {
                shownIndices.append(mid)
                skipOffset += 1
            }
            return
        }
        skipOffset = 0
        shownIndices = []
        if low >= high {
            resolvedBucketPosition = low
        }
    }

    /// Revert the most recent choice (including one that completed the
    /// session). No-op when there is nothing to undo.
    public mutating func undo() {
        guard let snapshot = history.popLast() else { return }
        low = snapshot.low
        high = snapshot.high
        skipOffset = snapshot.skipOffset
        shownIndices = snapshot.shownIndices
        comparisonsMade = snapshot.comparisonsMade
        resolvedBucketPosition = snapshot.resolvedBucketPosition
    }
}
