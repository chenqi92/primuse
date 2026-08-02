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

@Suite("Manual queue advance")
struct ManualQueueAdvancePolicyTests {
    @Test("Repeat-off single song does not restart itself")
    func singleSongNoOp() {
        #expect(!ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: 1,
            repeatMode: .off,
            shuffleEnabled: false,
            hasSuccessor: false
        ))
    }

    @Test("Shuffle single song advances after library extension")
    func shuffledSingleSongCanExtend() {
        #expect(ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: 1,
            repeatMode: .off,
            shuffleEnabled: true,
            hasSuccessor: true
        ))
    }

    @Test("Repeat modes may intentionally replay a single song")
    func repeatModesReplay() {
        #expect(ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: 1,
            repeatMode: .all,
            shuffleEnabled: false,
            hasSuccessor: true
        ))
        #expect(ManualQueueAdvancePolicy.shouldAdvance(
            queueCount: 1,
            repeatMode: .one,
            shuffleEnabled: false,
            hasSuccessor: true
        ))
    }
}

@Suite("Metadata backfill eligibility")
struct MetadataBackfillEligibilityPolicyTests {
    @Test("Inspected DTS with duration does not re-fetch metadata")
    func inspectedDTSIsComplete() {
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 245,
            format: .dts,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: true
        ))
    }

    @Test("Scanner acknowledgement does not hide missing duration")
    func bareSongStillBackfills() {
        #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 0,
            format: .dts,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: true
        ))
    }

    @Test("Inspected MP3 still gets one artwork attempt")
    func mp3ArtworkStillBackfills() {
        #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .mp3,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: true
        ))
    }

    @Test("Legacy uninspected songs retain title migration")
    func legacyTitleStillBackfills() {
        #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: false
        ))
    }
}

@Suite("Metadata backfill stall handling")
struct MetadataBackfillStallPolicyTests {
    @Test("An unchanged nonempty snapshot is parked for this session")
    func repeatedSnapshotIsParked() {
        #expect(MetadataBackfillStallPolicy.shouldParkRepeatedSnapshot(
            previousIDs: ["ftp-1", "sftp-1"],
            currentIDs: ["sftp-1", "ftp-1"]
        ))
    }

    @Test("The first or a progressing snapshot continues")
    func freshOrProgressingSnapshotContinues() {
        #expect(!MetadataBackfillStallPolicy.shouldParkRepeatedSnapshot(
            previousIDs: [],
            currentIDs: ["ftp-1"]
        ))
        #expect(!MetadataBackfillStallPolicy.shouldParkRepeatedSnapshot(
            previousIDs: ["ftp-1", "sftp-1"],
            currentIDs: ["sftp-1"]
        ))
    }
}
