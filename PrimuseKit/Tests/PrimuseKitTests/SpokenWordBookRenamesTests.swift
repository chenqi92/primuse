import Foundation
import Testing
@testable import PrimuseKit

@Suite("Spoken word book renames")
struct SpokenWordBookRenamesTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func file(_ number: Int, folder: String = "Novel", album: String? = nil) -> SpokenWordBookItem {
        SpokenWordBookItem(
            id: "\(folder)-\(number)", title: "Chapter-\(number)", albumTitle: album, duration: 30,
            fileName: "/Books/\(folder)/Chapter-\(number).mp3", sourceID: "s"
        )
    }

    // MARK: Finding the successor

    @Test("Reading the first tags moves the folder's book to the album's")
    func firstTagReadRenamesTheBook() throws {
        let before = SpokenWordBookGrouping.bookIDs(for: (1...4).map { file($0) })
        let after = SpokenWordBookGrouping.bookIDs(for: [file(1, album: "QA Book")] + (2...4).map { file($0) })
        let oldID = try #require(before["Novel-1"])
        let newID = try #require(after["Novel-1"])
        #expect(oldID != newID)
        #expect(SpokenWordBookGrouping.renamedBookIDs(from: before, to: after) == [oldID: newID])
        // Nothing changed, nothing renamed.
        #expect(SpokenWordBookGrouping.renamedBookIDs(from: after, to: after).isEmpty)
        #expect(SpokenWordBookGrouping.renamedBookIDs(from: [:], to: after).isEmpty)
    }

    @Test("Two folders joined by one album both go to it")
    func mergedBooksBothRename() {
        let before = ["a1": "folder:A", "a2": "folder:A", "b1": "folder:B", "b2": "folder:B"]
        let after = ["a1": "book:X", "a2": "book:X", "b1": "book:X", "b2": "book:X"]
        #expect(SpokenWordBookGrouping.renamedBookIDs(from: before, to: after) == [
            "folder:A": "book:X", "folder:B": "book:X",
        ])
    }

    @Test("A book needs most of the old one's chapters to take over")
    func majorityRequired() {
        // Scattered: no book holds more than half.
        let scattered = SpokenWordBookGrouping.renamedBookIDs(
            from: ["1": "old", "2": "old", "3": "old", "4": "old"],
            to: ["1": "x", "2": "x", "3": "y", "4": "z"]
        )
        #expect(scattered.isEmpty)
        // Chapters that left the library do not count against it.
        let shrunk = SpokenWordBookGrouping.renamedBookIDs(
            from: ["1": "old", "2": "old", "3": "old"],
            to: ["1": "x", "9": "y"]
        )
        #expect(shrunk == ["old": "x"])
        // A book that is still there keeps its id, even when part of it split off.
        let split = SpokenWordBookGrouping.renamedBookIDs(
            from: ["1": "b", "2": "b", "3": "b"],
            to: ["1": "b", "2": "b", "3": "b\u{1F}copy"]
        )
        #expect(split.isEmpty)
        // Two of three is most; an even split is not.
        let twoOfThree = SpokenWordBookGrouping.renamedBookIDs(
            from: ["1": "old", "2": "old", "3": "old"],
            to: ["1": "y", "2": "y", "3": "x"]
        )
        #expect(twoOfThree == ["old": "y"])
        let even = SpokenWordBookGrouping.renamedBookIDs(from: ["1": "old", "2": "old"], to: ["1": "x", "2": "y"])
        #expect(even.isEmpty)
    }

    // MARK: Orders kept on this device

    @Test("A renamed book takes the old id's place in an order")
    func orderCarriesPlace() {
        let renames = ["f1": "n1", "f2": "n2", "f3": "n1"]
        #expect(SpokenWordBookRenames.carrying(["a", "f1", "b"], renames: renames) == ["a", "n1", "b"])
        // The new id already placed keeps its own place.
        #expect(SpokenWordBookRenames.carrying(["n2", "a", "f2"], renames: renames) == ["n2", "a"])
        // Two old ids that became one book: the first place.
        #expect(SpokenWordBookRenames.carrying(["f3", "a", "f1"], renames: renames) == ["n1", "a"])
        // Kept old ids stay in front of the new one.
        #expect(SpokenWordBookRenames.carrying(["a", "f1", "b"], renames: renames, keepingOldIDs: true)
            == ["a", "f1", "n1", "b"])
        #expect(SpokenWordBookRenames.carrying(["a", "b"], renames: [:]) == ["a", "b"])
        // Carrying again changes nothing.
        let once = SpokenWordBookRenames.carrying(["a", "f1", "b"], renames: renames, keepingOldIDs: true)
        #expect(SpokenWordBookRenames.carrying(once, renames: renames, keepingOldIDs: true) == once)
    }

    @Test("A stale id finds its book through renames in a row and back")
    func historyFollowsChains() {
        var history = SpokenWordBookRenames.recording(["folder": "album"], into: [:])
        history = SpokenWordBookRenames.recording(["album": "album+author"], into: history)
        #expect(SpokenWordBookRenames.currentID(for: "folder", in: history) == "album+author")
        #expect(SpokenWordBookRenames.currentID(for: "album", in: history) == "album+author")
        #expect(SpokenWordBookRenames.currentID(for: "other", in: history) == "other")
        // Renamed back: the old id is current again and points nowhere.
        history = SpokenWordBookRenames.recording(["album+author": "folder"], into: history)
        #expect(SpokenWordBookRenames.currentID(for: "folder", in: history) == "folder")
        #expect(SpokenWordBookRenames.currentID(for: "album", in: history) == "folder")
        // Past the limit only the latest renames are kept.
        let capped = SpokenWordBookRenames.recording(["x": "y"], into: ["a": "b", "c": "d"], limit: 2)
        #expect(capped == ["x": "y"])
    }

    // MARK: Synced speed and archive

    private func rate(_ value: Float?, _ seconds: TimeInterval) -> SpokenWordSyncRegister<Float> {
        SpokenWordSyncRegister(value: value, stamp: t0.addingTimeInterval(seconds))
    }

    private func archived(_ value: Bool?, _ seconds: TimeInterval) -> SpokenWordSyncRegister<Bool> {
        SpokenWordSyncRegister(value: value, stamp: t0.addingTimeInterval(seconds))
    }

    @Test("Speed and archive are copied to the new id, the old id keeps them")
    func syncedStateIsCopied() {
        let state = SpokenWordSyncState(
            rates: ["folder": rate(1.5, 10)],
            archived: ["folder": archived(true, 20)]
        )
        let carried = SpokenWordSyncPolicy.carryingBookState(state, renames: ["folder": "album"])
        #expect(carried.rates["album"] == rate(1.5, 10))
        #expect(carried.archived["album"] == archived(true, 20))
        #expect(carried.rates["folder"] == rate(1.5, 10))
        #expect(carried.archived["folder"] == archived(true, 20))
        // Carrying again changes nothing.
        #expect(SpokenWordSyncPolicy.carryingBookState(carried, renames: ["folder": "album"]) == carried)
        // An unrelated rename leaves the state alone.
        #expect(SpokenWordSyncPolicy.carryingBookState(state, renames: ["x": "y"]) == state)
    }

    @Test("The newer setting stands; a removal adds nothing to a book with none")
    func newerSettingStands() {
        // The new id's own speed is newer: it stays.
        let ownNewer = SpokenWordSyncPolicy.carryingBookState(
            SpokenWordSyncState(rates: ["folder": rate(1.5, 10), "album": rate(2, 30)]),
            renames: ["folder": "album"]
        )
        #expect(ownNewer.rates["album"] == rate(2, 30))
        // Unarchived on the old id after the new one was archived: back on the shelf.
        let unarchived = SpokenWordSyncPolicy.carryingBookState(
            SpokenWordSyncState(archived: ["folder": archived(nil, 40), "album": archived(true, 30)]),
            renames: ["folder": "album"]
        )
        #expect(unarchived.archived["album"] == archived(nil, 40))
        // A cleared speed is not written onto a book that never had one.
        let cleared = SpokenWordSyncPolicy.carryingBookState(
            SpokenWordSyncState(rates: ["folder": rate(nil, 10)]),
            renames: ["folder": "album"]
        )
        #expect(cleared.rates["album"] == nil)
        // Two old books into one: the newest decision, whichever order they come in.
        let merged = SpokenWordSyncPolicy.carryingBookState(
            SpokenWordSyncState(rates: ["a": rate(1.2, 10), "b": rate(nil, 20)]),
            renames: ["a": "album", "b": "album"]
        )
        #expect(merged.rates["album"] == nil)
    }

    @Test("Devices carrying the same rename at different times agree")
    func devicesConverge() {
        let shared = SpokenWordSyncState(rates: ["folder": rate(1.5, 10)], archived: ["folder": archived(true, 20)])
        // A reads the tags first and carries; B still groups by folder and changes its speed.
        let deviceA = SpokenWordSyncPolicy.carryingBookState(shared, renames: ["folder": "album"])
        var deviceB = shared
        deviceB.rates["folder"] = rate(1.8, 50)
        // They sync before B reads the tags: B keeps its folder book's speed.
        let synced = SpokenWordSyncPolicy.merge(deviceA, deviceB)
        #expect(synced.rates["folder"] == rate(1.8, 50))
        #expect(synced.rates["album"] == rate(1.5, 10))
        // Then B reads the tags and carries: its newer speed reaches the album, and A agrees.
        let afterB = SpokenWordSyncPolicy.carryingBookState(synced, renames: ["folder": "album"])
        #expect(afterB.rates["album"] == rate(1.8, 50))
        #expect(SpokenWordSyncPolicy.merge(afterB, deviceA) == afterB)
        #expect(SpokenWordSyncPolicy.merge(deviceA, afterB) == afterB)
    }

    // MARK: Synced favourites

    private func member(_ collected: Bool, _ stamp: Double) -> FavoriteCollectionSyncState.Membership {
        .init(isCollected: collected, stamp: stamp)
    }

    @Test("A collected book is collected under its new id, right after the old one")
    func favouritesCarry() {
        let state = FavoriteCollectionSyncState(
            members: ["book:folder": member(true, 5), "playlist:p": member(true, 6)],
            order: .init(ids: ["playlist:p", "book:folder", "album:x"], stamp: 7)
        )
        let carried = FavoriteCollectionSyncPolicy.carryingMembership(state, renames: ["book:folder": "book:album"])
        #expect(carried.members["book:album"] == member(true, 5))
        #expect(carried.members["book:folder"] == member(true, 5))
        #expect(carried.order == .init(ids: ["playlist:p", "book:folder", "book:album", "album:x"], stamp: 7))
        #expect(FavoriteCollectionSyncPolicy.carryingMembership(carried, renames: ["book:folder": "book:album"]) == carried)
        // The carried order wins over the one without it at the same stamp.
        #expect(FavoriteCollectionSyncPolicy.merge(state, carried) == carried)
    }

    @Test("A newer removal of the new id stands, and books kept on this device are left alone")
    func favouritesRespectNewerRemoval() {
        let removed = FavoriteCollectionSyncPolicy.carryingMembership(
            FavoriteCollectionSyncState(
                members: ["book:folder": member(true, 5), "book:album": member(false, 9)],
                order: .init(ids: ["book:folder"], stamp: 7)
            ),
            renames: ["book:folder": "book:album"]
        )
        #expect(removed.members["book:album"] == member(false, 9))
        #expect(removed.order?.ids == ["book:folder"])
        let localOnly = FavoriteCollectionSyncState(members: ["playlist:p": member(true, 1)])
        #expect(FavoriteCollectionSyncPolicy.carryingMembership(localOnly, renames: ["book:folder": "book:album"])
            == localOnly)
    }

    // MARK: Offline books

    @Test("A book kept offline moves to its new id")
    func offlineBooksMove() {
        let records: [String: AudiobookOfflinePolicy.Record] = [
            "folder": .init(title: "Novel", songIDs: ["1", "2"]),
            "other": .init(title: "Other", songIDs: ["9"]),
        ]
        let moved = AudiobookOfflinePolicy.carrying(records, renames: ["folder": "album"])
        #expect(moved["folder"] == nil)
        #expect(moved["album"] == .init(title: "Novel", songIDs: ["1", "2"]))
        #expect(moved["other"] == records["other"])
        let joined = AudiobookOfflinePolicy.carrying(
            ["folder": .init(title: "Novel", songIDs: ["1", "2"]), "album": .init(title: "QA Book", songIDs: ["2", "3"])],
            renames: ["folder": "album"]
        )
        #expect(joined == ["album": .init(title: "QA Book", songIDs: ["1", "2", "3"])])
    }
}
