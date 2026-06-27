import XCTest
@testable import RankingEngine

final class InsertionSessionTests: XCTestCase {

    private func makeList(loved: [Int] = [], fine: [Int] = [], disliked: [Int] = []) -> RankingList<Int> {
        var items: [RankedItem<Int>] = []
        items += loved.map { RankedItem(id: $0, sentiment: .loved) }
        items += fine.map { RankedItem(id: $0, sentiment: .fine) }
        items += disliked.map { RankedItem(id: $0, sentiment: .disliked) }
        return RankingList(items: items)
    }

    // MARK: - Edge cases

    func testFirstMovieEverNeedsNoComparisons() {
        var list = RankingList<Int>()
        let session = list.beginInsertion(of: 1, sentiment: .loved)
        XCTAssertTrue(session.isComplete)
        XCTAssertNil(session.currentOpponent)
        XCTAssertEqual(session.expectedComparisons, 0)
        let scored = list.commit(session)
        XCTAssertEqual(scored.rank, 1)
        XCTAssertEqual(scored.score, 10.0)
    }

    func testFirstMovieInBucketNeedsNoComparisonsEvenWithOtherBucketsPopulated() {
        var list = makeList(loved: [1, 2, 3])
        let session = list.beginInsertion(of: 99, sentiment: .disliked)
        XCTAssertTrue(session.isComplete)
        list.commit(session)
        XCTAssertEqual(list.scoredItem(for: 99)?.rank, 4)
        XCTAssertEqual(list.scoredItem(for: 99)?.score, 3.3)
    }

    func testInsertWithoutComparisonsConvenience() {
        var list = RankingList<Int>()
        XCTAssertNotNil(list.insertWithoutComparisons(1, sentiment: .fine))
        // Second movie in the same bucket requires a comparison.
        XCTAssertNil(list.insertWithoutComparisons(2, sentiment: .fine))
        XCTAssertEqual(list.count, 1)
    }

    // MARK: - Binary search behavior

    func testAlwaysPreferNewLandsAtTopOfBucket() {
        var list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        while !session.isComplete { session.choose(.preferNew) }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved).first, 99)
        XCTAssertEqual(list.scoredItem(for: 99)?.score, 10.0)
    }

    func testAlwaysPreferExistingLandsAtBottomOfBucket() {
        var list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        while !session.isComplete { session.choose(.preferExisting) }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved).last, 99)
        XCTAssertEqual(list.scoredItem(for: 99)?.score, 6.7)
    }

    func testBinarySearchInsertsAtCorrectMiddlePosition() {
        // Bucket [10, 20, 30, 40, 50]; insert between 20 and 30.
        var list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 25, sentiment: .loved)
        while !session.isComplete, let opponent = session.currentOpponent {
            // User prefers the new movie over anything > 25, prefers smaller IDs.
            session.choose(opponent > 25 ? .preferNew : .preferExisting)
        }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved), [10, 20, 25, 30, 40, 50])
    }

    func testComparisonCountIsLogarithmic() {
        for n in [1, 2, 5, 10, 50, 100, 500] {
            let list = makeList(fine: Array(1...n))
            var session = list.beginInsertion(of: 9999, sentiment: .fine)
            let bound = Int(ceil(log2(Double(n + 1))))
            XCTAssertEqual(session.expectedComparisons, bound)
            while !session.isComplete { session.choose(.preferExisting) }
            XCTAssertLessThanOrEqual(session.comparisonsMade, bound, "n=\(n)")
        }
    }

    func testEveryInsertionPositionIsReachable() {
        // For a bucket of 7, all 8 insertion slots must be reachable by
        // some sequence of answers (binary search completeness).
        let n = 7
        for target in 0...n {
            var list = makeList(loved: Array(0..<n).map { $0 * 10 })
            var session = list.beginInsertion(of: 999, sentiment: .loved)
            while !session.isComplete, let idx = session.comparisonIndex {
                session.choose(idx >= target ? .preferNew : .preferExisting)
            }
            list.commit(session)
            XCTAssertEqual(list.bucket(.loved).firstIndex(of: 999), target)
        }
    }

    func testOpponentsComeFromCorrectBucketOnly() {
        let list = makeList(loved: [1, 2, 3], fine: [4, 5, 6], disliked: [7, 8])
        var session = list.beginInsertion(of: 99, sentiment: .fine)
        var seen: [Int] = []
        while !session.isComplete, let opponent = session.currentOpponent {
            seen.append(opponent)
            session.choose(.preferNew)
        }
        XCTAssertFalse(seen.isEmpty)
        XCTAssertTrue(seen.allSatisfy { [4, 5, 6].contains($0) })
    }

    // MARK: - Too tough to call

    func testSkipPlacesAdjacentToComparedTitle() {
        var list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let opponent = session.currentOpponent!   // middle item: 30
        XCTAssertEqual(opponent, 30)
        session.choose(.tooToughToCall)
        XCTAssertTrue(session.isComplete)
        list.commit(session)
        // Placed immediately below the compared title.
        let ids = list.bucket(.loved)
        XCTAssertEqual(ids.firstIndex(of: 99)!, ids.firstIndex(of: 30)! + 1)
    }

    func testSkipAfterSomeComparisons() {
        var list = makeList(fine: [10, 20, 30, 40, 50, 60, 70])
        var session = list.beginInsertion(of: 99, sentiment: .fine)
        session.choose(.preferNew)          // range narrows to top half
        let opponent = session.currentOpponent!
        session.choose(.tooToughToCall)
        list.commit(session)
        let ids = list.bucket(.fine)
        XCTAssertEqual(ids.firstIndex(of: 99)!, ids.firstIndex(of: opponent)! + 1)
    }

    func testTooToughTakesOnNearOpponentScore() {
        // CIN-13: "too tough to call" lands the new title right beside the one
        // it was compared against, so it takes on (very nearly) that score.
        var list = makeList(loved: Array(1...20))
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let opponent = session.currentOpponent!
        session.choose(.tooToughToCall)
        list.commit(session)
        let byID = Dictionary(uniqueKeysWithValues: list.scoredItems.map { ($0.id, $0.score) })
        // Adjacent placement → within a single score step of the opponent
        // (one rounded step in this band is ~0.2; allow a hair more for FP).
        XCTAssertLessThanOrEqual(abs(byID[99]! - byID[opponent]!), 0.25)
    }

    func testRepeatedSkipsAcrossInsertionsKeepDistinctPositions() {
        // "Ties" from skipping still produce a strict total order.
        var list = makeList(loved: [1])
        for id in 2...5 {
            var session = list.beginInsertion(of: id, sentiment: .loved)
            if !session.isComplete { session.choose(.tooToughToCall) }
            list.commit(session)
        }
        XCTAssertEqual(Set(list.bucket(.loved)).count, 5)
        let scores = list.scoredItems.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    // MARK: - Progress

    func testProgressAdvancesAndCompletes() {
        let list = makeList(loved: Array(1...20))
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        var last = -1.0
        while !session.isComplete {
            XCTAssertGreaterThanOrEqual(session.progress, last)
            last = session.progress
            session.choose(.preferExisting)
        }
        XCTAssertEqual(session.progress, 1.0)
    }

    // MARK: - Predicted-score seed + similarity hints

    func testNoSeedUsesMidpointOpponent() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        let session = list.beginInsertion(of: 99, sentiment: .loved)
        // span 5, midpoint index 2.
        XCTAssertEqual(session.currentOpponent, 30)
    }

    func testSeedPositionPicksFirstOpponent() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        // Predicted to slot at index 1 → first opponent is that title, not the median.
        let session = list.beginInsertion(of: 99, sentiment: .loved, seedPosition: 1)
        XCTAssertEqual(session.currentOpponent, 20)
    }

    func testSeedIsClampedIntoRange() {
        let list = makeList(loved: [10, 20, 30])
        // Out-of-range seed clamps to the last valid index (2).
        let session = list.beginInsertion(of: 99, sentiment: .loved, seedPosition: 99)
        XCTAssertEqual(session.currentOpponent, 30)
    }

    func testSimilarityBiasesOpponentTowardSimilarTitle() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        // Midpoint is index 2; window is index 1...3. The most-similar there is index 3.
        let sim = [0.0, 0.0, 0.1, 0.9, 0.0]
        let session = list.beginInsertion(of: 99, sentiment: .loved, similarity: sim)
        XCTAssertEqual(session.currentOpponent, 40)
    }

    func testMismatchedSimilarityIsIgnored() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        let session = list.beginInsertion(of: 99, sentiment: .loved, similarity: [0.9, 0.9])
        // Wrong-length array is dropped; falls back to the midpoint.
        XCTAssertEqual(session.currentOpponent, 30)
    }

    func testSeedAndSimilarityStillConvergeToTopWhenAlwaysPreferNew() {
        var list = makeList(loved: [10, 20, 30, 40, 50])
        let sim = [0.5, 0.5, 0.5, 0.5, 0.5]
        var session = list.beginInsertion(of: 99, sentiment: .loved,
                                          seedPosition: 3, similarity: sim)
        while !session.isComplete { session.choose(.preferNew) }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved).first, 99)
    }

    func testSeedStillConvergesToBottomWhenAlwaysPreferExisting() {
        var list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved, seedPosition: 1)
        while !session.isComplete { session.choose(.preferExisting) }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved).last, 99)
    }
}
