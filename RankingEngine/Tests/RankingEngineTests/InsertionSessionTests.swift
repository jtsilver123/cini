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
}
