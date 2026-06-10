import XCTest
@testable import RankingEngine

final class RankingListTests: XCTestCase {

    private func insert(_ id: Int, _ sentiment: Sentiment, into list: inout RankingList<Int>,
                        answers: (Int) -> ComparisonChoice = { _ in .preferExisting }) {
        var session = list.beginInsertion(of: id, sentiment: sentiment)
        while !session.isComplete, let opponent = session.currentOpponent {
            session.choose(answers(opponent))
        }
        list.commit(session)
    }

    // MARK: - Global ordering & scores

    func testGlobalRankOrdersBucketsLovedFineDisliked() {
        var list = RankingList<Int>()
        insert(1, .fine, into: &list)
        insert(2, .disliked, into: &list)
        insert(3, .loved, into: &list)
        let ranks = list.scoredItems
        XCTAssertEqual(ranks.map(\.id), [3, 1, 2])
        XCTAssertEqual(ranks.map(\.rank), [1, 2, 3])
    }

    func testScoresRecalculatedAfterEveryInsertion() {
        var list = RankingList<Int>()
        insert(1, .loved, into: &list)
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 10.0)

        // Insert a better movie: 1's score must drop — scores are relative.
        var session = list.beginInsertion(of: 2, sentiment: .loved)
        session.choose(.preferNew)
        list.commit(session)
        XCTAssertEqual(list.scoredItem(for: 2)?.score, 10.0)
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 6.7)

        var session3 = list.beginInsertion(of: 3, sentiment: .loved)
        while !session3.isComplete { session3.choose(.preferNew) }
        list.commit(session3)
        XCTAssertEqual(list.scoredItem(for: 3)?.score, 10.0)
        XCTAssertEqual(list.scoredItem(for: 2)?.score, 8.4)  // midpoint of band, recalculated
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 6.7)
    }

    func testScoresFallInSentimentBands() {
        var list = RankingList<Int>()
        for id in 1...10 { insert(id, .loved, into: &list) }
        for id in 11...20 { insert(id, .fine, into: &list) }
        for id in 21...30 { insert(id, .disliked, into: &list) }
        for item in list.scoredItems {
            XCTAssertTrue(item.sentiment.scoreRange.contains(item.score),
                          "\(item.id) score \(item.score) outside \(item.sentiment) band")
        }
        // Global ordering: scores strictly decrease with rank here.
        let scores = list.scoredItems.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    // MARK: - Re-ranking

    func testRerankingMovesItemWithinBucket() {
        var list = RankingList<Int>()
        for id in [1, 2, 3, 4, 5] { insert(id, .loved, into: &list) } // order 1..5
        XCTAssertEqual(list.bucket(.loved), [1, 2, 3, 4, 5])

        // "Rank again" on 5, now it beats everything.
        var session = list.beginReranking(of: 5, sentiment: .loved)
        while !session.isComplete { session.choose(.preferNew) }
        list.commit(session)
        XCTAssertEqual(list.bucket(.loved), [5, 1, 2, 3, 4])
        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.scoredItem(for: 5)?.score, 10.0)
    }

    func testRerankingCanChangeBucket() {
        var list = RankingList<Int>()
        insert(1, .loved, into: &list)
        insert(2, .loved, into: &list)
        let session = list.beginReranking(of: 2, sentiment: .disliked)
        XCTAssertTrue(session.isComplete) // first movie in disliked bucket
        list.commit(session)
        XCTAssertEqual(list.sentiment(of: 2), .disliked)
        XCTAssertEqual(list.bucket(.loved), [1])
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 10.0) // loved bucket rescored
    }

    func testRerankedItemIsNotItsOwnOpponent() {
        var list = RankingList<Int>()
        for id in 1...8 { insert(id, .fine, into: &list) }
        var session = list.beginReranking(of: 4, sentiment: .fine)
        while !session.isComplete, let opponent = session.currentOpponent {
            XCTAssertNotEqual(opponent, 4)
            session.choose(.preferExisting)
        }
        list.commit(session)
        XCTAssertEqual(list.count, 8)
    }

    // MARK: - Removal

    func testRemoveRescoresRemainingItems() {
        var list = RankingList<Int>()
        insert(1, .loved, into: &list)
        var session = list.beginInsertion(of: 2, sentiment: .loved)
        session.choose(.preferNew)
        list.commit(session)
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 6.7)
        XCTAssertTrue(list.remove(2))
        XCTAssertEqual(list.scoredItem(for: 1)?.score, 10.0)
        XCTAssertFalse(list.remove(2))
    }

    // MARK: - Persistence round-trip

    func testCodableRoundTripPreservesOrderAndScores() throws {
        var list = RankingList<Int>()
        for id in 1...12 { insert(id, [Sentiment.loved, .fine, .disliked][id % 3], into: &list) }
        let data = try JSONEncoder().encode(list)
        let decoded = try JSONDecoder().decode(RankingList<Int>.self, from: data)
        XCTAssertEqual(decoded.scoredItems, list.scoredItems)
    }

    func testInitFromPersistedItemsIgnoresDuplicates() {
        let items = [
            RankedItem(id: 1, sentiment: Sentiment.loved),
            RankedItem(id: 2, sentiment: .loved),
            RankedItem(id: 1, sentiment: .fine), // duplicate id — ignored
        ]
        let list = RankingList(items: items)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.sentiment(of: 1), .loved)
    }
}
