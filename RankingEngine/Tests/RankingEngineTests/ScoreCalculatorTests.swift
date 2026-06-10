import XCTest
@testable import RankingEngine

final class ScoreCalculatorTests: XCTestCase {

    func testEmptyBucket() {
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 0, sentiment: .loved), [])
    }

    func testSingleItemGetsTopOfBand() {
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 1, sentiment: .loved), [10.0])
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 1, sentiment: .fine), [6.6])
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 1, sentiment: .disliked), [3.3])
    }

    func testTwoItemsSpanTheBand() {
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 2, sentiment: .loved), [10.0, 6.7])
        XCTAssertEqual(ScoreCalculator.scores(forBucketOf: 2, sentiment: .disliked), [3.3, 0.0])
    }

    func testScoresAreLinearlySpaced() {
        let scores = ScoreCalculator.scores(forBucketOf: 4, sentiment: .loved)
        XCTAssertEqual(scores, [10.0, 8.9, 7.8, 6.7])
    }

    func testScoresStayWithinBand() {
        for sentiment in Sentiment.allCases {
            for n in 1...50 {
                let scores = ScoreCalculator.scores(forBucketOf: n, sentiment: sentiment)
                XCTAssertEqual(scores.count, n)
                for s in scores {
                    XCTAssertGreaterThanOrEqual(s, sentiment.scoreRange.lowerBound)
                    XCTAssertLessThanOrEqual(s, sentiment.scoreRange.upperBound)
                }
            }
        }
    }

    func testScoresAreMonotonicallyDecreasing() {
        let scores = ScoreCalculator.scores(forBucketOf: 30, sentiment: .fine)
        for i in 1..<scores.count {
            XCTAssertLessThan(scores[i], scores[i - 1])
        }
    }

    func testScoresRoundedToOneDecimal() {
        for sentiment in Sentiment.allCases {
            for s in ScoreCalculator.scores(forBucketOf: 7, sentiment: sentiment) {
                XCTAssertEqual(s, ScoreCalculator.round1(s))
            }
        }
    }

    func testSinglePositionMatchesFullBucket() {
        for sentiment in Sentiment.allCases {
            let full = ScoreCalculator.scores(forBucketOf: 9, sentiment: sentiment)
            for i in 0..<9 {
                XCTAssertEqual(ScoreCalculator.score(atBucketPosition: i, bucketCount: 9, sentiment: sentiment), full[i])
            }
        }
    }
}
