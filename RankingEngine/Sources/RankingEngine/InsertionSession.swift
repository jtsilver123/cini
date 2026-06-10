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

    private(set) var low: Int
    private(set) var high: Int
    private(set) var skipOffset: Int = 0
    public private(set) var comparisonsMade: Int = 0
    public private(set) var resolvedBucketPosition: Int?

    /// Snapshots for Undo, pushed before every accepted choice.
    private var history: [Snapshot] = []

    private struct Snapshot: Sendable {
        let low: Int
        let high: Int
        let skipOffset: Int
        let comparisonsMade: Int
        let resolvedBucketPosition: Int?
    }

    init(newItemID: ID, sentiment: Sentiment, bucketIDs: [ID]) {
        self.newItemID = newItemID
        self.sentiment = sentiment
        self.bucketIDs = bucketIDs
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
        return low + ((span / 2) + skipOffset) % span
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
                skipOffset += 1
            }
            return
        }
        skipOffset = 0
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
        comparisonsMade = snapshot.comparisonsMade
        resolvedBucketPosition = snapshot.resolvedBucketPosition
    }
}
