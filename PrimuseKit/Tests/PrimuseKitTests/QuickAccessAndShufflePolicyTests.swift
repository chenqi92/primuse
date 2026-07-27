import Foundation
import Testing
@testable import PrimuseKit

@Suite("Quick access persistence")
struct QuickAccessPinStorageCodecTests {
    private let liked = QuickAccessPinReference(kind: .playlist, itemID: "liked")

    @Test("Fresh storage defaults to Liked Songs")
    func defaultsLikedSongs() {
        #expect(QuickAccessPinStorageCodec.decode(
            "",
            defaultPins: [liked],
            maximumCount: 5
        ) == [liked])
    }

    @Test("Legacy arrays migrate Liked Songs into the ordered selection")
    func migratesLegacyArray() throws {
        let album = QuickAccessPinReference(kind: .album, itemID: "album-1")
        let legacy = String(decoding: try JSONEncoder().encode([album]), as: UTF8.self)

        #expect(QuickAccessPinStorageCodec.decode(
            legacy,
            defaultPins: [liked],
            maximumCount: 5
        ) == [liked, album])
    }

    @Test("Version 2 preserves an empty selection and custom order")
    func preservesDeselectionAndOrder() {
        let album = QuickAccessPinReference(kind: .album, itemID: "album-1")
        let artist = QuickAccessPinReference(kind: .artist, itemID: "artist-1")
        let encoded = QuickAccessPinStorageCodec.encode(
            [artist, liked, album],
            maximumCount: 5
        )
        #expect(QuickAccessPinStorageCodec.decode(
            encoded,
            defaultPins: [liked],
            maximumCount: 5
        ) == [artist, liked, album])

        let empty = QuickAccessPinStorageCodec.encode([], maximumCount: 5)
        #expect(QuickAccessPinStorageCodec.decode(
            empty,
            defaultPins: [liked],
            maximumCount: 5
        ).isEmpty)
    }
}

@Suite("Shuffle library continuation")
struct ShuffleContinuationPolicyTests {
    @Test("A one-song queue expands with other unique library tracks")
    func expandsSingleSongQueue() {
        #expect(ShuffleContinuationPolicy.candidateIDs(
            queueIDs: ["current"],
            libraryIDs: ["current", "next-a", "next-b", "next-a"],
            currentID: "current"
        ) == ["next-a", "next-b"])
    }

    @Test("Existing queue entries are never re-added")
    func excludesExistingQueue() {
        #expect(ShuffleContinuationPolicy.candidateIDs(
            queueIDs: ["a", "b"],
            libraryIDs: ["b", "c", "a", "d"],
            currentID: "b"
        ) == ["c", "d"])
    }
}
