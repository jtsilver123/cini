import XCTest
@testable import RankingEngine

final class UndoSkipTests: XCTestCase {

    private func makeList(loved: [Int]) -> RankingList<Int> {
        RankingList(items: loved.map { RankedItem(id: $0, sentiment: .loved) })
    }

    // MARK: - Undo

    func testUndoRestoresPreviousComparison() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let firstOpponent = session.currentOpponent
        XCTAssertFalse(session.canUndo)

        session.choose(.preferNew)
        XCTAssertNotEqual(session.currentOpponent, firstOpponent)
        XCTAssertTrue(session.canUndo)

        session.undo()
        XCTAssertEqual(session.currentOpponent, firstOpponent)
        XCTAssertEqual(session.comparisonsMade, 0)
        XCTAssertFalse(session.canUndo)
    }

    func testUndoRevertsCompletion() {
        let list = makeList(loved: [10, 20, 30])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        session.choose(.tooToughToCall)
        XCTAssertTrue(session.isComplete)

        session.undo()
        XCTAssertFalse(session.isComplete)
        XCTAssertNotNil(session.currentOpponent)
    }

    func testUndoOnFreshSessionIsNoOp() {
        let list = makeList(loved: [10, 20, 30])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let opponent = session.currentOpponent
        session.undo()
        XCTAssertEqual(session.currentOpponent, opponent)
    }

    func testMultipleUndosWalkAllTheWayBack() {
        let list = makeList(loved: Array(1...20))
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let initialOpponent = session.currentOpponent
        while !session.isComplete { session.choose(.preferExisting) }
        while session.canUndo { session.undo() }
        XCTAssertEqual(session.currentOpponent, initialOpponent)
        XCTAssertEqual(session.comparisonsMade, 0)
        XCTAssertFalse(session.isComplete)
    }

    // MARK: - Skip (different opponent, same range)

    func testSkipShowsDifferentOpponentWithoutNarrowingRange() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let firstOpponent = session.currentOpponent!
        session.choose(.skip)
        XCTAssertFalse(session.isComplete)
        XCTAssertNotEqual(session.currentOpponent, firstOpponent)
        // Search progress untouched: comparisons not counted for skips.
        XCTAssertEqual(session.comparisonsMade, 0)
    }

    func testSkipThenChoiceStillInsertsCorrectly() {
        // Insert 25 into [10, 20, 30, 40, 50] with one skip along the way.
        let list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 25, sentiment: .loved)
        session.choose(.skip)
        while !session.isComplete, let opponent = session.currentOpponent {
            session.choose(opponent > 25 ? .preferNew : .preferExisting)
        }
        var mutable = list
        mutable.commit(session)
        let ids = mutable.bucket(.loved)
        XCTAssertEqual(ids.firstIndex(of: 25)!, 2)
    }

    func testExhaustingSkipsPlacesAdjacent() {
        let list = makeList(loved: [10, 20, 30])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        var lastOpponentIndex: Int?
        var guardCounter = 0
        while !session.isComplete && guardCounter < 10 {
            lastOpponentIndex = session.comparisonIndex
            session.choose(.skip)
            guardCounter += 1
        }
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.resolvedBucketPosition, lastOpponentIndex! + 1)
    }

    func testSkipWithSingleCandidateResolvesImmediately() {
        let list = makeList(loved: [10])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        session.choose(.skip)
        XCTAssertTrue(session.isComplete)
        XCTAssertEqual(session.resolvedBucketPosition, 1) // just below the only title
    }

    func testUndoAfterSkipRestoresOriginalOpponent() {
        let list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved)
        let firstOpponent = session.currentOpponent
        session.choose(.skip)
        session.undo()
        XCTAssertEqual(session.currentOpponent, firstOpponent)
    }

    // MARK: - Skip never repeats an opponent (seed / similarity hints active)

    func testSkipNeverRepeatsOpponentUnderSimilarityBias() {
        // A dominant similarity spike used to be re-picked after every skip.
        var sim = Array(repeating: 0.0, count: 8)
        sim[4] = 1.0
        let list = makeList(loved: Array(1...8).map { $0 * 10 })
        var session = list.beginInsertion(of: 99, sentiment: .loved, similarity: sim)
        var seen = Set<Int>()
        while !session.isComplete, let opponent = session.currentOpponent {
            XCTAssertTrue(seen.insert(opponent).inserted,
                          "opponent \(opponent) shown twice across skips")
            session.choose(.skip)
        }
    }

    func testSkipAfterSeededFirstOpponentShowsDifferentTitle() {
        // Seed 3 collides with the post-skip rotation (0 + (2+1) % 5 == 3):
        // the same opponent used to come straight back.
        let list = makeList(loved: [10, 20, 30, 40, 50])
        var session = list.beginInsertion(of: 99, sentiment: .loved, seedPosition: 3)
        let firstOpponent = session.currentOpponent!
        session.choose(.skip)
        XCTAssertFalse(session.isComplete)
        XCTAssertNotEqual(session.currentOpponent, firstOpponent)
    }

    func testUndoAfterBiasedSkipRestoresOriginalOpponent() {
        var sim = Array(repeating: 0.0, count: 8)
        sim[4] = 1.0
        let list = makeList(loved: Array(1...8).map { $0 * 10 })
        var session = list.beginInsertion(of: 99, sentiment: .loved, similarity: sim)
        let firstOpponent = session.currentOpponent
        session.choose(.skip)
        XCTAssertNotEqual(session.currentOpponent, firstOpponent)
        session.undo()
        XCTAssertEqual(session.currentOpponent, firstOpponent)
    }

    func testSkipsStillConvergeWithHintsActive() {
        var sim = Array(repeating: 0.5, count: 10)
        sim[7] = 0.9
        let list = makeList(loved: Array(1...10).map { $0 * 10 })
        var session = list.beginInsertion(of: 99, sentiment: .loved,
                                          seedPosition: 7, similarity: sim)
        session.choose(.skip)
        while !session.isComplete, let opponent = session.currentOpponent {
            session.choose(opponent > 35 ? .preferNew : .preferExisting)
        }
        var mutable = list
        mutable.commit(session)
        // 99 preferred over everything > 35 → sits right after 30.
        let ids = mutable.bucket(.loved)
        XCTAssertEqual(ids.firstIndex(of: 99)!, ids.firstIndex(of: 30)! + 1)
    }
}
