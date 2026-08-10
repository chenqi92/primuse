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

    @Test("Server catalog MP3 with duration and cover skips a duplicate header read")
    func completeServerCatalogMP3DoesNotBackfill() {
        let titleChecked = ServerCatalogMetadataInspectionPolicy.hasUsableTitle("讲真的")
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .mp3,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: titleChecked
        ))
    }

    @Test("A placeholder catalog title retains the file-header fallback")
    func placeholderServerCatalogTitleStillBackfills() {
        let titleChecked = ServerCatalogMetadataInspectionPolicy.hasUsableTitle("未知标题")
        #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: titleChecked
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

@Suite("Server catalog metadata inspection")
struct ServerCatalogMetadataInspectionPolicyTests {
    @Test("A real server title completes title inspection")
    func realTitleIsUsable() {
        #expect(ServerCatalogMetadataInspectionPolicy.hasUsableTitle("讲真的"))
        #expect(ServerCatalogMetadataInspectionPolicy.hasUsableTitle("  A Real Song  "))
    }

    @Test("Missing and placeholder server titles keep the file-header fallback")
    func placeholdersRemainEligibleForInspection() {
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle(nil))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle(""))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("   "))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("Unknown"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("[Unknown Title]"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("Unknown Track"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("UNTITLED"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("未知标题"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("未知標題"))
        #expect(!ServerCatalogMetadataInspectionPolicy.hasUsableTitle("Broken � Title"))
    }
}

@Suite("Metadata backfill activity state")
struct MetadataBackfillActivityStateTests {
    @Test("Only an active worker resolves to running")
    func activeWorkerRuns() {
        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: true,
            isWaitingForWiFi: false
        ) == .running)
    }

    @Test("Wi-Fi deferral stays visible after its prompt is dismissed")
    func cellularDeferralWaits() {
        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: true
        ) == .waitingForWiFi)
    }

    @Test("Switching to Wi-Fi or allowing cellular resumes the running state")
    func permittedNetworkRuns() {
        let afterWiFiReconnect = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: true,
            isWaitingForWiFi: false
        )
        let afterCellularOptIn = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: true,
            isWaitingForWiFi: false
        )

        #expect(afterWiFiReconnect == .running)
        #expect(afterCellularOptIn == .running)
    }

    @Test("Cancellation and retryable failure leave a static pending state")
    func interruptedWorkStaysPending() {
        let afterCancellation = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: false
        )
        let afterRetryableFailure = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: false
        )

        #expect(afterCancellation == .pending)
        #expect(afterRetryableFailure == .pending)
    }

    @Test("Completed or failed-only queues become idle")
    func exhaustedQueuesAreIdle() {
        let noPendingWork = MetadataBackfillActivityState.resolve(
            hasPendingWork: false,
            isRunning: false,
            isWaitingForWiFi: false
        )
        let failedWorkExcludedFromQueue = MetadataBackfillActivityState.resolve(
            hasPendingWork: false,
            isRunning: false,
            isWaitingForWiFi: false
        )

        #expect(noPendingWork == .idle)
        #expect(failedWorkExcludedFromQueue == .idle)
    }

    @Test("Pending and idle queues do not present as running")
    func inactiveQueuesDoNotRun() {
        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: false
        ) == .pending)
        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: false,
            isRunning: false,
            isWaitingForWiFi: true
        ) == .idle)
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
