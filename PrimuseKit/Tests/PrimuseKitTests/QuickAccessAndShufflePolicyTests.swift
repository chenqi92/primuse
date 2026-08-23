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

    @Test("Each inspection reason is tracked independently")
    func independentWorkReasons() {
        let reasons = MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .mp3,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            hasAlbumTitle: true,
            hasAlbumArtist: false,
            albumArtistChecked: false
        )

        #expect(reasons == [.duration, .artwork, .title, .albumArtist])
    }

    @Test("A legitimately absent album artist completes after inspection")
    func absentAlbumArtistDoesNotLoop() {
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasAlbumTitle: true,
            hasAlbumArtist: false,
            albumArtistChecked: false
        ) == [.albumArtist])

        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasAlbumTitle: true,
            hasAlbumArtist: false,
            albumArtistChecked: true
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

    @Test("Cancellation stays pending while transient failures are labelled for retry")
    func interruptedWorkStaysPending() {
        let afterCancellation = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: false
        )
        let afterRetryableFailure = MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: false,
            isWaitingForWiFi: false,
            hasDeferredRetryWork: true
        )

        #expect(afterCancellation == .pending)
        #expect(afterRetryableFailure == .retryPending)
    }

    @Test("A relaunched transient request is identified as a retry")
    func carriedRetryIsVisible() {
        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: true,
            isRunning: true,
            isWaitingForWiFi: false,
            hasDeferredRetryWork: true
        ) == .retrying)

        #expect(MetadataBackfillActivityState.resolve(
            hasPendingWork: false,
            isRunning: false,
            isWaitingForWiFi: false,
            hasDeferredRetryWork: true
        ) == .retryPending)
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

    @Test("A source outage persists only the request that actually failed")
    func sourceOutageDoesNotPersistTheWholeSnapshot() {
        let snapshotIDs = Set((1...300).map { "synology-\($0)" })
        #expect(MetadataBackfillDeferredRetryPolicy.idsToPersist(
            failedSongID: "synology-3",
            snapshotSongIDs: snapshotIDs,
            cause: .sourceUnavailable
        ) == ["synology-3"])
        #expect(MetadataBackfillDeferredRetryPolicy.idsToPersist(
            failedSongID: nil,
            snapshotSongIDs: snapshotIDs,
            cause: .repeatedSnapshot
        ).isEmpty)
    }
}

@Suite("Synology FileStation download error classification")
struct SynologyFileStationDownloadErrorPolicyTests {
    @Test("Session, missing-file, and source errors keep distinct meanings")
    func dispositions() {
        #expect(SynologyFileStationDownloadErrorPolicy.disposition(code: 119) == .reconnectSession)
        #expect(SynologyFileStationDownloadErrorPolicy.disposition(code: 408) == .missingFile)
        #expect(SynologyFileStationDownloadErrorPolicy.disposition(code: 407) == .sourceUnavailable)
        #expect(SynologyFileStationDownloadErrorPolicy.disposition(code: 410) == .sourceUnavailable)
        #expect(SynologyFileStationDownloadErrorPolicy.disposition(code: 999) == .fail)
    }
}

@Suite("Cloud scan error classification")
struct CloudScanErrorClassificationTests {
    @Test("Baidu body error codes keep provider semantics")
    func baiduErrorCodes() {
        #expect(BaiduAPIErrorPolicy.disposition(errno: -9) == .missingPath)
        #expect(BaiduAPIErrorPolicy.disposition(errno: -6) == .refreshAuthentication)
        #expect(BaiduAPIErrorPolicy.disposition(errno: 111) == .refreshAuthentication)
        #expect(BaiduAPIErrorPolicy.disposition(errno: 31034) == .retryAfterBackoff)
        #expect(BaiduAPIErrorPolicy.disposition(errno: -1) == .fail)
    }

    @Test("Missing child checkpoints are discarded but missing roots fail")
    func missingDirectoryHandling() {
        #expect(ScanDirectoryFailurePolicy.disposition(
            isMissingPath: true,
            isSelectedRoot: false
        ) == .discardMissingChild)
        #expect(ScanDirectoryFailurePolicy.disposition(
            isMissingPath: true,
            isSelectedRoot: true
        ) == .failMissingRoot)
        #expect(ScanDirectoryFailurePolicy.disposition(
            isMissingPath: false,
            isSelectedRoot: false
        ) == .retainForResume)
    }

    @Test("Only transient HTTP statuses use bounded request retry")
    func cloudHTTPRetryStatuses() {
        #expect(CloudHTTPRetryPolicy.shouldRetry(statusCode: 408))
        #expect(CloudHTTPRetryPolicy.shouldRetry(statusCode: 425))
        #expect(CloudHTTPRetryPolicy.shouldRetry(statusCode: 429))
        #expect(CloudHTTPRetryPolicy.shouldRetry(statusCode: 503))
        #expect(!CloudHTTPRetryPolicy.shouldRetry(statusCode: 401))
        #expect(!CloudHTTPRetryPolicy.shouldRetry(statusCode: 403))
        #expect(!CloudHTTPRetryPolicy.shouldRetry(statusCode: 404))
        #expect(CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: URLError.timedOut.rawValue))
        #expect(CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: URLError.networkConnectionLost.rawValue))
        #expect(!CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: URLError.cancelled.rawValue))
    }

    @Test("Google quota reasons remain retryable while ordinary 403 is permanent")
    func googleDrive403Reasons() {
        #expect(GoogleDriveHTTPErrorPolicy.disposition(
            statusCode: 403,
            reasons: ["rateLimitExceeded"]
        ) == .retryRateLimit)
        #expect(GoogleDriveHTTPErrorPolicy.disposition(
            statusCode: 403,
            reasons: ["userRateLimitExceeded"]
        ) == .retryRateLimit)
        #expect(GoogleDriveHTTPErrorPolicy.disposition(
            statusCode: 403,
            reasons: ["insufficientFilePermissions"]
        ) == .permissionDenied)
    }

    @Test("Pagination rejects empty and non-adjacent repeated tokens")
    func paginationRequiresGlobalProgress() {
        #expect(!CloudPaginationTokenPolicy.canAdvance(to: "", seenTokens: []))
        #expect(CloudPaginationTokenPolicy.canAdvance(to: "page-b", seenTokens: ["page-a"]))
        #expect(!CloudPaginationTokenPolicy.canAdvance(
            to: "page-a",
            seenTokens: ["page-a", "page-b"]
        ))
    }
}

@Suite("Baidu metadata replacement verification")
struct BaiduMetadataReplacementVerificationPolicyTests {
    @Test("Authoritative size and opaque provider revision confirm the replacement")
    func committedFileMatches() {
        #expect(BaiduMetadataReplacementVerificationPolicy.matchesCommittedFile(
            remoteSize: 496_538,
            remoteRevision: "3c8be8999s78bd7d50b56ab2a757044d",
            expectedSize: 496_538
        ))
    }

    @Test("Missing revision or mismatched size rejects the replacement")
    func committedFileDoesNotMatch() {
        #expect(!BaiduMetadataReplacementVerificationPolicy.matchesCommittedFile(
            remoteSize: 496_538,
            remoteRevision: nil,
            expectedSize: 496_538
        ))
        #expect(!BaiduMetadataReplacementVerificationPolicy.matchesCommittedFile(
            remoteSize: 496_537,
            remoteRevision: "3c8be8999s78bd7d50b56ab2a757044d",
            expectedSize: 496_538
        ))
        #expect(!BaiduMetadataReplacementVerificationPolicy.matchesCommittedFile(
            remoteSize: 496_538,
            remoteRevision: "   ",
            expectedSize: 496_538
        ))
    }
}
