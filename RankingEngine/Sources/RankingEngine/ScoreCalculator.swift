import Foundation

/// Derives 0–10 scores from rank positions. Scores are purely relative:
/// they are recomputed for the whole bucket after every insertion, removal,
/// or move — never stored as absolute ratings.
public enum ScoreCalculator {

    /// Scores a bucket of `count` items. Index 0 is the best item.
    ///
    /// Items are spread linearly from the top of the bucket's band down to
    /// the bottom. A bucket with a single item gets the top of the band
    /// (your only "loved" movie is a 10.0 — it's your #1).
    public static func scores(forBucketOf count: Int, sentiment: Sentiment) -> [Double] {
        guard count > 0 else { return [] }
        let range = sentiment.scoreRange
        guard count > 1 else { return [round1(range.upperBound)] }
        let span = range.upperBound - range.lowerBound
        let step = span / Double(count - 1)
        return (0..<count).map { round1(range.upperBound - Double($0) * step) }
    }

    /// Score for a single position without materializing the whole bucket.
    public static func score(atBucketPosition position: Int, bucketCount: Int, sentiment: Sentiment) -> Double {
        precondition(position >= 0 && position < bucketCount, "position out of bounds")
        let range = sentiment.scoreRange
        guard bucketCount > 1 else { return round1(range.upperBound) }
        let span = range.upperBound - range.lowerBound
        let step = span / Double(bucketCount - 1)
        return round1(range.upperBound - Double(position) * step)
    }

    static func round1(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
