import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word: following the book to another device's item")
struct SpokenWordBookFollowPolicyTests {
    private let chapters = (1...6).map { "ch-\($0)" }
    private let monday = Date(timeIntervalSince1970: 1_000_000)
    private var tuesday: Date { monday.addingTimeInterval(86_400) }
    private var wednesday: Date { monday.addingTimeInterval(2 * 86_400) }

    private func record(_ id: String, finished: Bool = false, at date: Date) -> SpokenWordBookFollowPolicy.Record {
        .init(itemID: id, isFinished: finished, updatedAt: date)
    }

    @Test("A chapter heard elsewhere after this device last touched its chapter wins")
    func newerChapterElsewhere() {
        let target = SpokenWordBookFollowPolicy.target(
            itemIDs: chapters,
            currentItemID: "ch-2",
            anchor: monday,
            records: [record("ch-2", at: monday), record("ch-5", at: tuesday)]
        )
        #expect(target == "ch-5")
    }

    @Test("Records older than this device's last touch never move it")
    func olderRecordsStay() {
        let target = SpokenWordBookFollowPolicy.target(
            itemIDs: chapters,
            currentItemID: "ch-2",
            anchor: wednesday,
            records: [record("ch-5", at: tuesday), record("ch-6", finished: true, at: monday)]
        )
        #expect(target == nil)
    }

    @Test("A newest record on the current item keeps it; a finished one moves to the next item")
    func currentItem() {
        #expect(SpokenWordBookFollowPolicy.target(
            itemIDs: chapters, currentItemID: "ch-2", anchor: monday,
            records: [record("ch-2", at: tuesday)]
        ) == nil)
        #expect(SpokenWordBookFollowPolicy.target(
            itemIDs: chapters, currentItemID: "ch-2", anchor: monday,
            records: [record("ch-2", finished: true, at: tuesday)]
        ) == "ch-3")
    }

    @Test("Finishing the item before the current one leaves the player where it is")
    func finishedPreviousItem() {
        let target = SpokenWordBookFollowPolicy.target(
            itemIDs: chapters,
            currentItemID: "ch-3",
            anchor: nil,
            records: [record("ch-1", at: monday), record("ch-2", finished: true, at: tuesday)]
        )
        #expect(target == nil)
    }

    @Test("Finishing the last item has nothing to follow")
    func finishedLastItem() {
        #expect(SpokenWordBookFollowPolicy.target(
            itemIDs: chapters, currentItemID: "ch-2", anchor: monday,
            records: [record("ch-6", finished: true, at: tuesday)]
        ) == nil)
    }

    @Test("Equal stamps (one book-wide server time) pick the later item in reading order")
    func equalStamps() {
        let target = SpokenWordBookFollowPolicy.target(
            itemIDs: chapters,
            currentItemID: "ch-1",
            anchor: monday,
            records: [
                record("ch-1", finished: true, at: tuesday),
                record("ch-2", finished: true, at: tuesday),
                record("ch-3", at: tuesday),
            ]
        )
        #expect(target == "ch-3")
    }

    @Test("Items outside the book and an unknown current item are ignored")
    func outsideTheBook() {
        #expect(SpokenWordBookFollowPolicy.target(
            itemIDs: chapters, currentItemID: "ch-2", anchor: monday,
            records: [record("other-book", at: wednesday)]
        ) == nil)
        #expect(SpokenWordBookFollowPolicy.target(
            itemIDs: chapters, currentItemID: "elsewhere", anchor: monday,
            records: [record("ch-5", at: wednesday)]
        ) == nil)
    }

    @Test("A record is the later of the position and the finish")
    func recordFromStamps() {
        #expect(SpokenWordBookFollowPolicy.Record(itemID: "a", positionUpdatedAt: nil, finishedAt: nil) == nil)
        let replay = SpokenWordBookFollowPolicy.Record(itemID: "a", positionUpdatedAt: tuesday, finishedAt: monday)
        #expect(replay?.isFinished == false)
        #expect(replay?.updatedAt == tuesday)
        let finished = SpokenWordBookFollowPolicy.Record(itemID: "a", positionUpdatedAt: monday, finishedAt: tuesday)
        #expect(finished?.isFinished == true)
        #expect(SpokenWordBookFollowPolicy.Record(itemID: "a", positionUpdatedAt: nil, finishedAt: monday)?.isFinished == true)
    }
}
