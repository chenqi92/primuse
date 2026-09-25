import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken-word sync merge")
struct SpokenWordSyncPolicyTests {
    private typealias Policy = SpokenWordSyncPolicy
    private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

    private func position(_ p: TimeInterval, _ stamp: Date) -> SpokenWordSyncRegister<SpokenWordSyncPosition> {
        SpokenWordSyncRegister(value: SpokenWordSyncPosition(position: p, duration: 3600), stamp: stamp)
    }

    private func bookmark(_ id: UUID, song: String = "s1", position: TimeInterval = 10, title: String = "a", created: Date) -> SpokenWordBookmark {
        SpokenWordBookmark(id: id, songID: song, position: position, title: title, createdAt: created)
    }

    // MARK: Registers

    @Test func newerPositionWins() {
        let a = SpokenWordSyncState(positions: ["s1": position(100, at(10))])
        let b = SpokenWordSyncState(positions: ["s1": position(200, at(20))])
        #expect(Policy.merge(a, b).positions["s1"]?.value?.position == 200)
        #expect(Policy.merge(b, a).positions["s1"]?.value?.position == 200)
    }

    @Test func positionsFromBothSidesAreKept() {
        let a = SpokenWordSyncState(positions: ["s1": position(100, at(10))])
        let b = SpokenWordSyncState(positions: ["s2": position(200, at(20))])
        let merged = Policy.merge(a, b)
        #expect(merged.positions.count == 2)
    }

    @Test func clearedPositionTombstoneBeatsOlderValue() {
        let local = SpokenWordSyncState(positions: ["s1": .init(value: nil, stamp: at(30))])
        let remote = SpokenWordSyncState(positions: ["s1": position(500, at(20))])
        #expect(Policy.merge(local, remote).positions["s1"]?.value == nil)
        // …but a later listen elsewhere revives it.
        let later = SpokenWordSyncState(positions: ["s1": position(600, at(40))])
        #expect(Policy.merge(local, later).positions["s1"]?.value?.position == 600)
    }

    @Test func finishedNewestWinsAndUnfinishedTombstoneSticks() {
        let finished = SpokenWordSyncState(finished: ["s1": .init(value: true, stamp: at(10))])
        let unfinished = SpokenWordSyncState(finished: ["s1": .init(value: nil, stamp: at(20))])
        #expect(Policy.merge(finished, unfinished).finished["s1"]?.value == nil)
        #expect(Policy.merge(unfinished, finished).finished["s1"]?.value == nil)
    }

    @Test func finishingDropsAnOlderPosition() {
        let a = SpokenWordSyncState(positions: ["s1": position(100, at(10))])
        let b = SpokenWordSyncState(finished: ["s1": .init(value: true, stamp: at(20))])
        let merged = Policy.merge(a, b)
        #expect(merged.finished["s1"]?.value == true)
        #expect(merged.positions["s1"]?.value == nil)
        #expect(merged.positions["s1"]?.stamp == at(20))
    }

    @Test func listeningAgainReopensAFinishedItem() {
        let a = SpokenWordSyncState(positions: ["s1": position(100, at(30))])
        let b = SpokenWordSyncState(finished: ["s1": .init(value: true, stamp: at(20))])
        let merged = Policy.merge(a, b)
        #expect(merged.positions["s1"]?.value?.position == 100)
        #expect(merged.finished["s1"]?.value == nil)
    }

    @Test func tieBreakIsCommutative() {
        let a = SpokenWordSyncState(rates: ["book": .init(value: 1.5, stamp: at(5))])
        let b = SpokenWordSyncState(rates: ["book": .init(value: 1.25, stamp: at(5))])
        #expect(Policy.merge(a, b) == Policy.merge(b, a))
        let c = SpokenWordSyncState(rates: ["book": .init(value: nil, stamp: at(5))])
        #expect(Policy.merge(a, c).rates["book"]?.value == nil)
        #expect(Policy.merge(c, a).rates["book"]?.value == nil)
    }

    @Test func mergeIsIdempotentAndAssociative() {
        let id = UUID()
        let a = SpokenWordSyncState(
            positions: ["s1": position(100, at(10)), "s2": position(5, at(3))],
            overrides: ["s9": .init(value: "music", stamp: at(1))],
            bookmarks: [id.uuidString: .init(value: bookmark(id, created: at(2)), stamp: at(2))]
        )
        let b = SpokenWordSyncState(
            positions: ["s1": position(200, at(20))],
            finished: ["s2": .init(value: true, stamp: at(4))],
            rates: ["book": .init(value: 1.5, stamp: at(6))]
        )
        let c = SpokenWordSyncState(
            overrides: ["s9": .init(value: nil, stamp: at(7))],
            bookmarks: [id.uuidString: .init(value: nil, stamp: at(8))]
        )
        let ab = Policy.merge(a, b)
        #expect(Policy.merge(ab, ab) == ab)
        #expect(Policy.merge(Policy.merge(a, b), c) == Policy.merge(a, Policy.merge(b, c)))
        #expect(Policy.merge(Policy.merge(a, b), c) == Policy.merge(Policy.merge(c, a), b))
    }

    // MARK: Bookmarks

    @Test func bookmarksUnionByID() {
        let one = UUID(), two = UUID()
        let a = SpokenWordSyncState(bookmarks: [one.uuidString: .init(value: bookmark(one, created: at(1)), stamp: at(1))])
        let b = SpokenWordSyncState(bookmarks: [two.uuidString: .init(value: bookmark(two, position: 50, created: at(2)), stamp: at(2))])
        let merged = Policy.merge(a, b)
        #expect(merged.bookmarks.count == 2)
        let records = Policy.records(from: merged)
        #expect(records.bookmarks["s1"]?.map(\.id) == [one, two])
    }

    @Test func deletedBookmarkDoesNotComeBack() {
        let id = UUID()
        let live = SpokenWordSyncState(bookmarks: [id.uuidString: .init(value: bookmark(id, created: at(1)), stamp: at(1))])
        let deleted = SpokenWordSyncState(bookmarks: [id.uuidString: .init(value: nil, stamp: at(9))])
        let merged = Policy.merge(live, deleted)
        #expect(merged.bookmarks[id.uuidString]?.value == nil)
        #expect(Policy.records(from: merged).bookmarks.isEmpty)
        #expect(Policy.records(from: merged).ledger.bookmarkDeletedAt[id.uuidString] == at(9))
    }

    @Test func renamedBookmarkNewestWins() {
        let id = UUID()
        let original = bookmark(id, title: "old", created: at(1))
        var renamed = original
        renamed.title = "new"
        let a = SpokenWordSyncState(bookmarks: [id.uuidString: .init(value: original, stamp: at(1))])
        let b = SpokenWordSyncState(bookmarks: [id.uuidString: .init(value: renamed, stamp: at(5))])
        #expect(Policy.merge(a, b).bookmarks[id.uuidString]?.value?.title == "new")
    }

    // MARK: Local records

    @Test func recordsRoundTripThroughState() {
        let id = UUID()
        var records = SpokenWordLocalRecords(
            positions: ["s1": .init(position: 42, duration: 100, updatedAt: at(10))],
            finishedAt: ["s2": at(11)],
            bookmarks: ["s1": [bookmark(id, created: at(3))]],
            overrides: ["s3": "spokenWord"],
            bookRates: ["book:x": 1.5]
        )
        records.ledger.positionClearedAt["s4"] = at(12)
        records.ledger.unfinishedAt["s5"] = at(13)
        records.ledger.overrideChangedAt["s3"] = at(14)
        records.ledger.overrideChangedAt["s6"] = at(15)
        records.ledger.rateChangedAt["book:x"] = at(16)
        records.ledger.bookmarkDeletedAt["gone"] = at(17)

        let state = Policy.state(from: records)
        #expect(state.overrides["s6"]?.value == nil)
        #expect(state.overrides["s6"]?.stamp == at(15))
        let back = Policy.records(from: state)
        #expect(back == records)
    }

    @Test func legacyOverrideWithoutStampLosesToAnyChange() {
        let legacy = Policy.state(from: SpokenWordLocalRecords(overrides: ["s1": "spokenWord"]))
        #expect(legacy.overrides["s1"]?.stamp == .distantPast)
        let changed = SpokenWordSyncState(overrides: ["s1": .init(value: nil, stamp: at(1))])
        #expect(Policy.records(from: Policy.merge(legacy, changed)).overrides["s1"] == nil)
    }

    @Test func staleLedgerTombstoneDoesNotHideANewerValue() {
        var records = SpokenWordLocalRecords(positions: ["s1": .init(position: 5, duration: 100, updatedAt: at(20))])
        records.ledger.positionClearedAt["s1"] = at(10)
        #expect(Policy.state(from: records).positions["s1"]?.value?.position == 5)
    }

    // MARK: Pruning and upload

    @Test func pruningDropsExpiredTombstonesOnly() {
        let now = at(Policy.tombstoneLifetime + 100)
        let state = SpokenWordSyncState(
            positions: [
                "old-tomb": .init(value: nil, stamp: at(0)),
                "old-live": position(1, at(0)),
                "new-tomb": .init(value: nil, stamp: at(Policy.tombstoneLifetime + 50)),
            ]
        )
        let pruned = Policy.pruned(state, now: now)
        #expect(pruned.positions["old-tomb"] == nil)
        #expect(pruned.positions["old-live"] != nil)
        #expect(pruned.positions["new-tomb"] != nil)
    }

    @Test func pruningCapsByRecency() {
        var positions: [String: SpokenWordSyncRegister<SpokenWordSyncPosition>] = [:]
        for index in 0..<(Policy.maximumPositions + 20) {
            positions["s\(index)"] = position(1, at(TimeInterval(index)))
        }
        let pruned = Policy.pruned(SpokenWordSyncState(positions: positions), now: at(0))
        #expect(pruned.positions.count == Policy.maximumPositions)
        #expect(pruned.positions["s0"] == nil)
        #expect(pruned.positions["s\(Policy.maximumPositions + 19)"] != nil)
    }

    @Test func uploadFitsBudgetDroppingTombstonesThenOldest() throws {
        var state = SpokenWordSyncState()
        for index in 0..<400 {
            state.positions[String(repeating: "a", count: 40) + "\(index)"] = position(Double(index), at(TimeInterval(index)))
        }
        for index in 0..<100 {
            state.finished["t\(index)"] = .init(value: nil, stamp: at(1000 + TimeInterval(index)))
        }
        let budget = 20_000
        let upload = Policy.uploadState(state, byteBudget: budget)
        let size = try #require(Policy.encode(upload)?.count)
        #expect(size <= budget)
        #expect(upload.finished.isEmpty)
        #expect(upload.positions[String(repeating: "a", count: 40) + "399"] != nil)
        #expect(upload.positions[String(repeating: "a", count: 40) + "0"] == nil)
        // Deterministic: the same state always yields the same document.
        #expect(Policy.uploadState(state, byteBudget: budget) == upload)
        // A state that fits is untouched.
        #expect(Policy.uploadState(upload, byteBudget: budget) == upload)
    }

    @Test func realisticFullStateFitsDefaultBudget() throws {
        // 1000 positions with 64-character ids, the worst case the store allows.
        var state = SpokenWordSyncState()
        for index in 0..<Policy.maximumPositions {
            let id = String(format: "%064d", index)
            state.positions[id] = position(Double(index) * 13.7, at(TimeInterval(index)))
        }
        let size = try #require(Policy.encode(state)?.count)
        #expect(size < Policy.uploadByteBudget)
    }

    @Test func encodingRoundTripsAndOmitsEmptySections() throws {
        let state = SpokenWordSyncState(rates: ["b": .init(value: 1.25, stamp: at(1))])
        let data = try #require(Policy.encode(state))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("\"p\""))
        #expect(Policy.decode(data) == state)
        #expect(Policy.decode(Data("{}".utf8)) == .empty)
        #expect(Policy.decode(Data("garbage".utf8)) == nil)
        #expect(Policy.decode(nil) == nil)
    }

    @Test func ledgerDecodesFromPartialJSON() throws {
        let data = Data(#"{"unfinishedAt":{"s1":1}}"#.utf8)
        let ledger = try JSONDecoder().decode(SpokenWordSyncLedger.self, from: data)
        #expect(ledger.unfinishedAt["s1"] == Date(timeIntervalSinceReferenceDate: 1))
        #expect(ledger.positionClearedAt.isEmpty)
    }
}

@Suite("Spoken-word book playback")
struct SpokenWordBookPlaybackPolicyTests {
    @Test func bookIDMatchesGrouping() {
        let items = [
            SpokenWordBookItem(id: "1", title: "Ch 1", albumTitle: "Book", albumArtist: "Author", duration: 10),
            SpokenWordBookItem(id: "2", title: "Ch 2", albumTitle: "Book", albumArtist: "Author", duration: 10),
            SpokenWordBookItem(id: "3", title: "Lone", duration: 10),
        ]
        let books = SpokenWordBookGrouping.books(from: items)
        for book in books {
            for item in book.items {
                #expect(SpokenWordBookGrouping.bookID(for: item) == book.id)
            }
        }
    }

    @Test func bookRateFallsBackToGlobal() {
        #expect(SpokenWordPlaybackRatePolicy.bookRate(stored: nil, globalSpokenWordRate: 1.25) == 1.25)
        #expect(SpokenWordPlaybackRatePolicy.bookRate(stored: 1.75, globalSpokenWordRate: 1.25) == 1.75)
        #expect(SpokenWordPlaybackRatePolicy.bookRate(stored: 9, globalSpokenWordRate: 1) == 2)
        #expect(SpokenWordPlaybackRatePolicy.bookRate(stored: .nan, globalSpokenWordRate: 1.5) == 1.5)
    }

    @Test func storedBookRateIsNilWhenEqualToGlobal() {
        #expect(SpokenWordPlaybackRatePolicy.storedBookRate(for: 1.25, globalSpokenWordRate: 1.25) == nil)
        #expect(SpokenWordPlaybackRatePolicy.storedBookRate(for: 1.5, globalSpokenWordRate: 1.25) == 1.5)
        #expect(SpokenWordPlaybackRatePolicy.storedBookRate(for: 5, globalSpokenWordRate: 1) == 2)
    }

    @Test func adjacentItems() {
        let ids = ["a", "b", "c"]
        #expect(SpokenWordBookNavigationPolicy.adjacentItemID(from: "b", offset: 1, in: ids) == "c")
        #expect(SpokenWordBookNavigationPolicy.adjacentItemID(from: "b", offset: -1, in: ids) == "a")
        #expect(SpokenWordBookNavigationPolicy.adjacentItemID(from: "c", offset: 1, in: ids) == nil)
        #expect(SpokenWordBookNavigationPolicy.adjacentItemID(from: "a", offset: -1, in: ids) == nil)
        #expect(SpokenWordBookNavigationPolicy.adjacentItemID(from: "x", offset: 1, in: ids) == nil)
        #expect(SpokenWordBookNavigationPolicy.previousRestartsCurrentItem(currentTime: 10))
        #expect(!SpokenWordBookNavigationPolicy.previousRestartsCurrentItem(currentTime: 1))
    }
}
