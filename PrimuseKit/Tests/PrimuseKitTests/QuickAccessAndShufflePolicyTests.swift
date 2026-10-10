import Foundation
import Testing
@testable import PrimuseKit

@Suite("Quick access persistence")
struct QuickAccessPinStorageCodecTests {
    private let liked = QuickAccessPinReference(kind: .playlist, itemID: "liked")

    @Test("Fresh storage defaults to Liked Songs")
    func defaultsLikedSongs() {
        #expect(QuickAccessPinStorageCodec.decode("", defaultPins: [liked]) == [liked])
    }

    @Test("Legacy arrays migrate Liked Songs into the ordered selection")
    func migratesLegacyArray() throws {
        let album = QuickAccessPinReference(kind: .album, itemID: "album-1")
        let legacy = String(decoding: try JSONEncoder().encode([album]), as: UTF8.self)

        #expect(QuickAccessPinStorageCodec.decode(legacy, defaultPins: [liked]) == [liked, album])
    }

    @Test("Version 2 preserves an empty selection and custom order")
    func preservesDeselectionAndOrder() {
        let album = QuickAccessPinReference(kind: .album, itemID: "album-1")
        let artist = QuickAccessPinReference(kind: .artist, itemID: "artist-1")
        let encoded = QuickAccessPinStorageCodec.encode([artist, liked, album])
        #expect(QuickAccessPinStorageCodec.decode(encoded, defaultPins: [liked]) == [artist, liked, album])

        let empty = QuickAccessPinStorageCodec.encode([])
        #expect(QuickAccessPinStorageCodec.decode(empty, defaultPins: [liked]).isEmpty)
    }

    @Test("Favorites keep every entry instead of stopping at the old limit of twelve")
    func keepsEveryEntry() {
        let pins = (0..<40).map { QuickAccessPinReference(kind: .album, itemID: "album-\($0)") }
        let decoded = QuickAccessPinStorageCodec.decode(
            QuickAccessPinStorageCodec.encode(pins + [pins[3]]),
            defaultPins: [liked]
        )
        #expect(decoded == pins)
    }

    @Test("An entry of a kind this build does not know is skipped, the rest survive")
    func skipsUnknownKinds() {
        let raw = #"{"version":2,"pins":[{"kind":"playlist","itemID":"liked"},{"kind":"station","itemID":"s1"},{"kind":"album","itemID":"a1"}]}"#
        #expect(QuickAccessPinStorageCodec.decode(raw, defaultPins: []) == [
            liked,
            QuickAccessPinReference(kind: .album, itemID: "a1"),
        ])
    }

    @Test("Folder favorites round-trip through their item ID")
    func folderReferenceRoundTrip() {
        let node = LibraryFolderNodeID(sourceID: "nas-1", kind: .folder, normalizedRelativePath: "Music/Jazz|Live")
        let pin = QuickAccessPinReference.folder(node)
        #expect(pin.kind == .folder)
        #expect(pin.folderNodeID == node)
        #expect(QuickAccessPinReference.folder(node) == pin)

        let root = LibraryFolderNodeID(sourceID: "nas-1", kind: .source, normalizedRelativePath: "")
        #expect(QuickAccessPinReference.folder(root).folderNodeID == root)
        #expect(QuickAccessPinReference(kind: .album, itemID: pin.itemID).folderNodeID == nil)
    }
}

@Suite("Favorite collection order")
struct FavoriteCollectionOrderPolicyTests {
    private let liked = QuickAccessPinReference(kind: .playlist, itemID: "liked")
    private let a = QuickAccessPinReference(kind: .album, itemID: "a")
    private let b = QuickAccessPinReference(kind: .artist, itemID: "b")
    private let c = QuickAccessPinReference(kind: .playlist, itemID: "c")
    private let d = QuickAccessPinReference(kind: .album, itemID: "d")

    @Test("A new favorite goes first, right after a leading Liked Songs")
    func insertsAfterLeadingAnchor() {
        #expect(FavoriteCollectionOrderPolicy.inserting([c], into: [liked, a, b], anchor: liked) == [liked, c, a, b])
        #expect(FavoriteCollectionOrderPolicy.inserting([c], into: [a, liked, b], anchor: liked) == [c, a, liked, b])
        #expect(FavoriteCollectionOrderPolicy.inserting([c], into: [], anchor: liked) == [c])
    }

    @Test("Favoriting something already in the list moves it to the front instead of duplicating it")
    func movesExistingEntry() {
        #expect(FavoriteCollectionOrderPolicy.inserting([b], into: [liked, a, b], anchor: liked) == [liked, b, a])
        #expect(FavoriteCollectionOrderPolicy.inserting([d, a, d], into: [liked, a, b], anchor: liked) == [liked, d, a, b])
    }

    @Test("Liked Songs added back goes to the very front")
    func reAddedAnchorLeads() {
        #expect(FavoriteCollectionOrderPolicy.inserting([liked], into: [a, b], anchor: liked) == [liked, a, b])
    }

    @Test("Display order drops what is no longer a favorite and leads with favorites not yet ordered")
    func mergesMembership() {
        let merged = FavoriteCollectionOrderPolicy.merged(
            stored: [liked, a, b, c, a],
            isCollected: { $0 != b },
            collectedButUnordered: [d, a],
            anchor: liked
        )
        #expect(merged == [liked, d, a, c])
    }

    @Test("Without a leading Liked Songs the unordered favorites simply go first")
    func mergesWithoutAnchor() {
        let merged = FavoriteCollectionOrderPolicy.merged(
            stored: [a, liked],
            isCollected: { _ in true },
            collectedButUnordered: [d],
            anchor: liked
        )
        #expect(merged == [d, a, liked])
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

    @Test("FLAC and MPEG-4 audio get one embedded artwork attempt")
    func containerArtworkStillBackfills() {
        for format in [AudioFormat.flac, .m4a, .alac] {
            #expect(MetadataBackfillEligibilityPolicy.needsBackfill(
                duration: 180,
                format: format,
                hasCoverArt: false,
                artworkGivenUp: false,
                titleChecked: true
            ))
            #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
                duration: 180,
                format: format,
                hasCoverArt: false,
                artworkGivenUp: true,
                titleChecked: true
            ))
        }
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
            albumArtistChecked: false,
            hasArtist: false,
            artistChecked: false
        )

        #expect(reasons == [.duration, .artwork, .title, .albumArtist, .artist])
    }

    @Test("An M4A whose codec is unknown is read once, bare-row sources included")
    func unreadContainerCodecIsInspected() {
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .m4a,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            audioCodecUnread: true
        ) == [.audioCodec])

        // 本机与群晖读完一遍就收手, 但老库里的 M4A 要补读这一次才分得出无损。
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .m4a,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            restrictToBareRows: true,
            audioCodecUnread: true
        ) == [.audioCodec])

        // 读过就记在歌上, 不再排队。
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .m4a,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            restrictToBareRows: true,
            audioCodecUnread: false
        ))
    }

    @Test("Server catalogues are read only for an unknown container codec")
    func serverCatalogueReadsOnlyContainerCodec() {
        // Navidrome 给的歌缺封面、缺艺术家也不读文件: 那些以服务端为准。
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .m4a,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            hasAlbumTitle: true,
            hasAlbumArtist: false,
            albumArtistChecked: false,
            hasArtist: false,
            artistChecked: false,
            audioCodecUnread: true,
            effectiveBitDepthUnread: true,
            containerCodecOnly: true
        ) == [.audioCodec])

        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 0,
            format: .flac,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            effectiveBitDepthUnread: true,
            containerCodecOnly: true
        ))
        #expect(MusicSourceType.navidrome.readsContainerCodecFromFileHeader)
        #expect(!MusicSourceType.jellyfin.readsContainerCodecFromFileHeader)
        #expect(!MusicSourceType.webdav.readsContainerCodecFromFileHeader)
    }

    @Test("A 24-bit FLAC is checked for zero padding once")
    func unreadEffectiveBitDepthIsInspected() {
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            restrictToBareRows: true,
            effectiveBitDepthUnread: true
        ) == [.effectiveBitDepth])
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            effectiveBitDepthUnread: false
        ))
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

    @Test("An album artist no neighbour can confirm is reread once")
    func unconfirmedAlbumArtistIsReread() {
        // 早先为了补标题读过一次文件, 于是这一腿被当成检查完了; 存着的值只是
        // 回退成曲目艺术家。整库判定说它定不了案, 就该再读一次。
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasAlbumTitle: true,
            hasAlbumArtist: true,
            albumArtistChecked: true,
            albumArtistUnconfirmed: true
        ) == [.albumArtist])

        // 读完以后调用方会记下这一笔, 判定不再成立, 不会每轮重排。
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasAlbumTitle: true,
            hasAlbumArtist: true,
            albumArtistChecked: true,
            albumArtistUnconfirmed: false
        ))

        // 没有专辑名就无从谈专辑归属, 判定也不该把它拉进队列。
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasAlbumTitle: false,
            hasAlbumArtist: true,
            albumArtistChecked: true,
            albumArtistUnconfirmed: true
        ))

        // 本机与群晖是裸行源, 读完一遍就不再读。这一条要是把它们也挡在外面,
        // 修的就正好不是出问题的那类库。
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            restrictToBareRows: true,
            hasAlbumTitle: true,
            hasAlbumArtist: true,
            albumArtistChecked: true,
            albumArtistUnconfirmed: true
        ) == [.albumArtist])

        // 判定不成立时, 裸行源照旧一行都不重读。
        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .mp3,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true,
            hasAlbumTitle: true,
            hasAlbumArtist: false,
            albumArtistChecked: false
        ))
    }

    @Test("A missing track artist gets one independent inspection")
    func missingTrackArtistDoesNotLoop() {
        #expect(MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasArtist: false,
            artistChecked: false
        ) == [.artist])

        #expect(!MetadataBackfillEligibilityPolicy.needsBackfill(
            duration: 180,
            format: .flac,
            hasCoverArt: true,
            artworkGivenUp: false,
            titleChecked: true,
            hasArtist: false,
            artistChecked: true
        ))
    }
}

@Suite("WebDAV playback metadata backfill")
struct PlaybackMetadataBackfillPolicyTests {
    @Test("Only an incomplete WebDAV file starts an on-demand tag read")
    func webDAVOnlyAdmission() {
        #expect(PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: .webdav,
            hasMissingMetadata: true,
            isCueTrack: false,
            isStreamDescriptor: false,
            isAlreadyReading: false,
            completedForCurrentFile: false,
            failedAttemptCount: 0
        ))
        #expect(!PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: .smb,
            hasMissingMetadata: true,
            isCueTrack: false,
            isStreamDescriptor: false,
            isAlreadyReading: false,
            completedForCurrentFile: false,
            failedAttemptCount: 0
        ))
        #expect(!PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: .webdav,
            hasMissingMetadata: false,
            isCueTrack: false,
            isStreamDescriptor: false,
            isAlreadyReading: false,
            completedForCurrentFile: false,
            failedAttemptCount: 0
        ))
    }

    @Test("Duplicate, completed, CUE, and STRM requests stay suppressed")
    func duplicateAndUnsupportedRowsStaySuppressed() {
        for state in [
            (true, false, false, false),
            (false, true, false, false),
            (false, false, true, false),
            (false, false, false, true),
        ] {
            #expect(!PlaybackMetadataBackfillPolicy.shouldStart(
                sourceType: .webdav,
                hasMissingMetadata: true,
                isCueTrack: state.2,
                isStreamDescriptor: state.3,
                isAlreadyReading: state.0,
                completedForCurrentFile: state.1,
                failedAttemptCount: 0
            ))
        }
    }

    @Test("Transient playback failures use bounded backoff and cancellation is neutral")
    func boundedRetryAndCancellation() {
        #expect(PlaybackMetadataBackfillPolicy.retryDelay(afterFailedAttempt: 1) == 2)
        #expect(PlaybackMetadataBackfillPolicy.retryDelay(afterFailedAttempt: 2) == 8)
        #expect(PlaybackMetadataBackfillPolicy.retryDelay(afterFailedAttempt: 3) == nil)
        #expect(PlaybackMetadataBackfillPolicy.shouldCountFailure(
            isCancellation: false,
            isTransient: true
        ))
        #expect(!PlaybackMetadataBackfillPolicy.shouldCountFailure(
            isCancellation: true,
            isTransient: true
        ))
        #expect(!PlaybackMetadataBackfillPolicy.shouldCountFailure(
            isCancellation: false,
            isTransient: false
        ))
        #expect(!PlaybackMetadataBackfillPolicy.shouldStart(
            sourceType: .webdav,
            hasMissingMetadata: true,
            isCueTrack: false,
            isStreamDescriptor: false,
            isAlreadyReading: false,
            completedForCurrentFile: false,
            failedAttemptCount: PlaybackMetadataBackfillPolicy.maximumAttemptsPerPlayback
        ))
    }

    @Test("Core metadata gaps are detected for the TV playback path")
    func detectsCoreMetadataGaps() {
        #expect(PlaybackMetadataBackfillPolicy.hasMissingCoreMetadata(
            title: "Track",
            artistName: nil,
            albumTitle: "Album",
            duration: 180
        ))
        #expect(PlaybackMetadataBackfillPolicy.hasMissingCoreMetadata(
            title: "Track",
            artistName: "Artist",
            albumTitle: "Album",
            duration: 0
        ))
        #expect(!PlaybackMetadataBackfillPolicy.hasMissingCoreMetadata(
            title: "Track",
            artistName: "Artist",
            albumTitle: "Album",
            duration: 180
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

    @Test("Normal pending work is not relabelled by a smaller retry queue")
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
        #expect(afterRetryableFailure == .pending)
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
