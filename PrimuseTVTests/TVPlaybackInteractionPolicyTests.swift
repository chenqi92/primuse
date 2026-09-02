#if os(tvOS)
import Foundation
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVContentFocusRoutingTests: XCTestCase {
    func testHorizontalTabTraversalDoesNotIssueContentFocus() {
        var state = TVContentFocusRoutingState()

        XCTAssertNil(state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song))
        XCTAssertNil(state.contentModeDidChange(in: .nowPlaying, nowPlayingMode: .liveRadio))
        XCTAssertNil(state.latestRequest)
    }

    func testExplicitDownEntersNowPlayingAndReturnRestoresTabRouting() {
        var state = TVContentFocusRoutingState()

        let request = state.moveDown(from: .nowPlaying, nowPlayingMode: .song)
        XCTAssertEqual(request?.target, .nowPlaying(.songPrimary))
        XCTAssertEqual(
            state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song)?.target,
            .nowPlaying(.songPrimary)
        )

        state.returnToTabs()
        XCTAssertNil(state.latestRequest)
        XCTAssertNil(state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song))
    }

    func testEmptyNowPlayingCannotReceiveContentFocus() {
        var state = TVContentFocusRoutingState()
        XCTAssertNil(state.moveDown(from: .nowPlaying, nowPlayingMode: .empty))
        XCTAssertNil(state.latestRequest)
    }

    func testSourcesDownRoutesToPrimaryAddAction() {
        var state = TVContentFocusRoutingState()

        let request = state.moveDown(from: .sources, nowPlayingMode: .empty)

        XCTAssertEqual(request?.target, .sourcesPrimary)
        XCTAssertEqual(state.latestRequest?.target, .sourcesPrimary)
    }

    func testLibraryNavigationOnlyIssuesFocusRequest() {
        var state = TVContentFocusRoutingState()
        XCTAssertEqual(
            state.moveDown(from: .library, nowPlayingMode: .song)?.target,
            .libraryDefault
        )
    }
}

@MainActor
final class TVTabFocusSelectionPolicyTests: XCTestCase {
    func testModalPresentationSuppressesFocusDrivenTabSelection() {
        XCTAssertNil(
            TVTabFocusSelectionPolicy.selection(
                focused: .home,
                active: .sources,
                allowsFocusDrivenSelection: false
            )
        )
    }

    func testFocusDrivenTabSelectionResumesAfterModalRecovery() {
        XCTAssertEqual(
            TVTabFocusSelectionPolicy.selection(
                focused: .home,
                active: .sources,
                allowsFocusDrivenSelection: true
            ),
            .home
        )
    }

    func testMissingOrAlreadyActiveFocusDoesNotReselectTab() {
        XCTAssertNil(
            TVTabFocusSelectionPolicy.selection(
                focused: nil,
                active: .sources,
                allowsFocusDrivenSelection: true
            )
        )
        XCTAssertNil(
            TVTabFocusSelectionPolicy.selection(
                focused: .sources,
                active: .sources,
                allowsFocusDrivenSelection: true
            )
        )
    }
}

final class TVPlaybackCommandRoutingPolicyTests: XCTestCase {
    func testNavigationFocusMenuAndModalDismissalNeverRoutePlayback() {
        for input in [
            TVPlaybackInput.direction,
            .focusChanged,
            .menu,
            .modalDismissed,
        ] {
            XCTAssertEqual(
                TVPlaybackCommandRoutingPolicy.action(for: input),
                .none,
                "Unexpected playback action for \(input)"
            )
        }
    }

    func testEachSystemTransportInputRoutesExactlyOneMatchingAction() {
        let routedActions = [
            TVPlaybackInput.systemPlay,
            .systemPause,
            .systemToggle,
        ].map(TVPlaybackCommandRoutingPolicy.action(for:))
        let allRoutedActions = TVPlaybackInput.allCases.map(
            TVPlaybackCommandRoutingPolicy.action(for:)
        )

        XCTAssertEqual(routedActions, [.resume, .pause, .toggle])
        XCTAssertEqual(allRoutedActions.filter { $0 == .resume }.count, 1)
        XCTAssertEqual(allRoutedActions.filter { $0 == .pause }.count, 1)
        XCTAssertEqual(allRoutedActions.filter { $0 == .toggle }.count, 1)
        XCTAssertFalse(routedActions.contains(.none))
    }

    func testMediaRemoteCommandCenterIsTheGlobalPlaybackCommandOwner() {
        XCTAssertEqual(
            TVPlaybackCommandRoutingPolicy.globalOwner,
            .mediaRemoteCommandCenter
        )
    }
}

@MainActor
final class TVSourceLocalLibraryPolicyTests: XCTestCase {
    func testOnlySelfScanningSourcesAreAddableOnAppleTV() {
        XCTAssertEqual(TVStore.addableTypes, [.fnMusic, .daoliyu, .smb])
        for type in TVStore.addableTypes {
            XCTAssertTrue(TVStore.canBuildLibraryOnTV(type), type.rawValue)
            XCTAssertEqual(TVSourceLocalLibraryPolicy.capability(for: type), .directScan)
        }
    }

    func testConfigurationOnlySourcesRequirePairedLibrary() {
        for type in [
            MusicSourceType.subsonic,
            .navidrome,
            .jellyfin,
            .synology,
            .webdav,
            .ftp,
            .sftp,
            .nfs,
            .oneDrive,
            .dropbox,
        ] {
            XCTAssertEqual(
                TVSourceLocalLibraryPolicy.capability(for: type),
                .pairedLibrary,
                type.rawValue
            )
            XCTAssertFalse(TVStore.canBuildLibraryOnTV(type), type.rawValue)
        }
    }

    func testUnpublishedProviderAPIsStayUnavailable() {
        XCTAssertEqual(TVSourceLocalLibraryPolicy.capability(for: .ugreen), .unavailable)
        XCTAssertEqual(TVSourceLocalLibraryPolicy.capability(for: .fnos), .unavailable)
    }

    func testNewSelfScanningSourceContinuesIntoScanFlow() {
        for type in TVStore.addableTypes {
            XCTAssertEqual(
                TVSourceSaveContinuationPolicy.destination(isNewSource: true, type: type),
                .scan
            )
        }
        XCTAssertEqual(
            TVSourceSaveContinuationPolicy.destination(isNewSource: false, type: .smb),
            .sources
        )
        XCTAssertEqual(
            TVSourceSaveContinuationPolicy.destination(isNewSource: true, type: .jellyfin),
            .sources
        )
    }

    func testNewEmptyScannableSourceRequiresInitialScan() {
        XCTAssertEqual(
            TVSourceInitialScanPolicy.state(
                canScan: true,
                lastScannedAt: nil,
                actualSongCount: 0
            ),
            .pending
        )
    }

    func testSyncedSMBWithSongsAndNoLocalScanDateIsAlreadyUsable() {
        XCTAssertEqual(
            TVSourceInitialScanPolicy.state(
                canScan: true,
                lastScannedAt: nil,
                actualSongCount: 42
            ),
            .complete
        )
    }

    func testInitialScanStateUsesScanDateAndCapabilityBoundaries() {
        XCTAssertEqual(
            TVSourceInitialScanPolicy.state(
                canScan: true,
                lastScannedAt: Date(timeIntervalSince1970: 1),
                actualSongCount: 0
            ),
            .complete
        )
        XCTAssertEqual(
            TVSourceInitialScanPolicy.state(
                canScan: false,
                lastScannedAt: nil,
                actualSongCount: 0
            ),
            .notRequired
        )
        XCTAssertEqual(
            TVSourceInitialScanPolicy.state(
                canScan: false,
                lastScannedAt: Date(timeIntervalSince1970: 1),
                actualSongCount: 42
            ),
            .notRequired
        )
    }

    func testSecondSourceCannotStartWhileAnotherScanIsActive() {
        XCTAssertTrue(
            TVScanAdmissionPolicy.canStart(
                activeSourceID: nil,
                requestedSourceID: "source-1"
            )
        )
        XCTAssertFalse(
            TVScanAdmissionPolicy.canStart(
                activeSourceID: "source-1",
                requestedSourceID: "source-2"
            )
        )
        XCTAssertTrue(
            TVScanAdmissionPolicy.canStart(
                activeSourceID: nil,
                requestedSourceID: "source-2"
            )
        )
    }
}

@MainActor
final class TVScanProgressPresentationPolicyTests: XCTestCase {
    func testInProgressPhasesStayOnScanningPresentation() {
        for phase in [
            TVSourceScanner.Phase.idle,
            .browsing,
            .scanning,
        ] {
            XCTAssertEqual(
                TVScanProgressPresentationPolicy.state(for: phase),
                .scanning
            )
        }
    }

    func testCompletedScanUsesCompletionPresentation() {
        XCTAssertEqual(
            TVScanProgressPresentationPolicy.state(for: .done),
            .complete
        )
    }

    func testFailedScanUsesFailurePresentation() {
        XCTAssertEqual(
            TVScanProgressPresentationPolicy.state(for: .failed("network unavailable")),
            .failed
        )
    }
}

@MainActor
final class SourcesStoreDurabilityTests: XCTestCase {
    func testAddDurablySurvivesStoreReinitialization() throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "PrimuseTVTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }
        let source = MusicSource(
            id: "durable-add-\(UUID().uuidString)",
            name: "Durable Source",
            type: .smb,
            host: "nas.example.invalid",
            shareName: "Music"
        )

        let store = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        try store.addDurably(source)

        let reloadedStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        XCTAssertEqual(reloadedStore.source(id: source.id)?.name, source.name)
        XCTAssertEqual(reloadedStore.source(id: source.id)?.host, source.host)
        XCTAssertEqual(reloadedStore.source(id: source.id)?.shareName, source.shareName)
    }

    func testFailedDurableUpdatePreservesMemoryAndDisk() throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "PrimuseTVTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }
        let source = MusicSource(
            id: "durable-update-\(UUID().uuidString)",
            name: "Original Name",
            type: .smb,
            host: "nas.example.invalid",
            shareName: "Music"
        )
        let initialStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        try initialStore.addDurably(source)

        let failingStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            sourceDataWriter: { _, _ in
                throw SourcesStoreDurabilityTestError.injectedWriteFailure
            }
        )

        XCTAssertThrowsError(
            try failingStore.updateDurably(source.id) { $0.name = "Unsaved Name" }
        ) { error in
            XCTAssertEqual(
                error as? SourcesStoreDurabilityTestError,
                .injectedWriteFailure
            )
        }
        XCTAssertEqual(failingStore.source(id: source.id)?.name, source.name)

        let reloadedStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        XCTAssertEqual(reloadedStore.source(id: source.id)?.name, source.name)
    }

    func testTVSourceUpdateFailureRestoresSourceAndExactCredential() throws {
        let fileManager = FileManager.default
        let sourceID = "tv-source-transaction-\(UUID().uuidString)"
        let storageDirectoryURL = fileManager.temporaryDirectory.appendingPathComponent(
            "PrimuseTVTests-\(UUID().uuidString)",
            isDirectory: true
        )
        defer {
            _ = TVCredentialStore.clearLocalCredential(sourceID: sourceID)
            try? fileManager.removeItem(at: storageDirectoryURL)
        }

        let originalSource = MusicSource(
            id: sourceID,
            name: "Original Feiniu Source",
            type: .fnMusic,
            host: "old.example.invalid",
            username: "old-user"
        )
        let initialStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        try initialStore.addDurably(originalSource)
        XCTAssertTrue(
            TVCredentialStore.replaceLocalCredential(
                sourceID: sourceID,
                username: "old-user",
                password: "old-password",
                accessCode: nil
            )
        )

        let failingStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            sourceDataWriter: { _, _ in
                throw SourcesStoreDurabilityTestError.injectedWriteFailure
            }
        )
        let store = TVStore(sourcesStore: failingStore)
        var editedSource = originalSource
        editedSource.name = "Unsaved Feiniu Source"
        editedSource.host = "new.example.invalid"
        editedSource.username = "new-user"

        XCTAssertFalse(
            store.updateSource(
                editedSource,
                password: "new-password",
                fnConnectAccessCode: "new-access-code"
            )
        )
        XCTAssertEqual(failingStore.source(id: sourceID)?.name, originalSource.name)
        XCTAssertEqual(failingStore.source(id: sourceID)?.host, originalSource.host)
        XCTAssertEqual(failingStore.source(id: sourceID)?.username, originalSource.username)

        let reloadedStore = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL
        )
        XCTAssertEqual(reloadedStore.source(id: sourceID)?.name, originalSource.name)
        XCTAssertEqual(reloadedStore.source(id: sourceID)?.host, originalSource.host)
        XCTAssertEqual(reloadedStore.source(id: sourceID)?.username, originalSource.username)

        let restoredCredential = try XCTUnwrap(
            TVCredentialStore.loadLocalCredential(sourceID: sourceID)
        )
        XCTAssertEqual(restoredCredential.username, "old-user")
        XCTAssertEqual(restoredCredential.password, "old-password")
        XCTAssertNil(restoredCredential.accessCode)
    }
}

@MainActor
final class SourcePermanentDeletionTests: XCTestCase {
    func testCredentialCleanupKeepsMainActorResponsiveAndRejectsRestoreAndDuplicateDelete() async throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }

        let purger = ControlledSourceCredentialPurger()
        let source = deletedSource(id: "controlled-purge")
        let store = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            credentialPurger: { source in await purger.purge(source) }
        )
        try store.addDurably(source)

        let deletion = Task { await store.permanentlyDelete(id: source.id) }
        await purger.waitUntilStarted()

        XCTAssertTrue(store.permanentDeletionInProgressIDs.contains(source.id))
        XCTAssertEqual(store.source(id: source.id)?.isDeleted, true)

        store.restore(id: source.id)
        XCTAssertEqual(store.source(id: source.id)?.isDeleted, true)

        let duplicateResult = await store.permanentlyDelete(id: source.id)
        XCTAssertEqual(duplicateResult, .alreadyInProgress)

        let mainActorHeartbeat = Task { @MainActor in true }
        let mainActorResponded = await mainActorHeartbeat.value
        XCTAssertTrue(mainActorResponded)

        await purger.finish(with: true)
        let result = await deletion.value

        XCTAssertEqual(result, .deleted)
        XCTAssertNil(store.source(id: source.id))
        XCTAssertFalse(store.permanentDeletionInProgressIDs.contains(source.id))
        XCTAssertNotNil(store.sourceDeletionRecord(id: source.id))
    }

    func testCredentialCleanupFailureRetainsRetryableTombstoneThenSucceeds() async throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }

        let purger = SequencedSourceCredentialPurger(results: [false, true])
        let source = deletedSource(id: "retry-purge")
        let store = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            credentialPurger: { source in await purger.purge(source) }
        )
        try store.addDurably(source)

        let failedResult = await store.permanentlyDelete(id: source.id)
        XCTAssertEqual(failedResult, .credentialCleanupFailed)
        XCTAssertEqual(store.source(id: source.id)?.isDeleted, true)
        XCTAssertTrue(store.permanentDeletionFailureIDs.contains(source.id))
        XCTAssertFalse(store.permanentDeletionInProgressIDs.contains(source.id))

        let retryResult = await store.permanentlyDelete(id: source.id)
        XCTAssertEqual(retryResult, .deleted)
        XCTAssertNil(store.source(id: source.id))
        XCTAssertFalse(store.permanentDeletionFailureIDs.contains(source.id))
    }

    func testChangedTombstoneIsNotRemovedAfterCredentialCleanupCompletes() async throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }

        let purger = ControlledSourceCredentialPurger()
        let source = deletedSource(id: "changed-tombstone")
        let store = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            credentialPurger: { source in await purger.purge(source) }
        )
        try store.addDurably(source)

        let deletion = Task { await store.permanentlyDelete(id: source.id) }
        await purger.waitUntilStarted()
        store.updateLocal(source.id) {
            $0.deletedAt = ($0.deletedAt ?? Date()).addingTimeInterval(1)
        }
        await purger.finish(with: true)

        let result = await deletion.value
        XCTAssertEqual(result, .sourceChanged)
        XCTAssertNotNil(store.source(id: source.id))
        XCTAssertFalse(store.permanentDeletionFailureIDs.contains(source.id))
        XCTAssertFalse(store.permanentDeletionInProgressIDs.contains(source.id))
    }

    func testBatchDeletionReportsIndependentSuccessAndFailureWithoutRemoteWork() async throws {
        let fileManager = FileManager.default
        let storageDirectoryURL = temporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: storageDirectoryURL) }

        let successfulID = "batch-success"
        let failedID = "batch-failure"
        let purger = RecordingSourceCredentialPurger(failedIDs: [failedID])
        let store = SourcesStore(
            fileManager: fileManager,
            storageDirectoryURL: storageDirectoryURL,
            credentialPurger: { source in await purger.purge(source) }
        )
        try store.addDurably(deletedSource(id: successfulID))
        try store.addDurably(deletedSource(id: failedID))

        let results = await store.permanentlyDelete(ids: [successfulID, failedID])
        let purgedIDs = await purger.purgedIDs()

        XCTAssertEqual(results[successfulID], .deleted)
        XCTAssertEqual(results[failedID], .credentialCleanupFailed)
        XCTAssertNil(store.source(id: successfulID))
        XCTAssertEqual(store.source(id: failedID)?.isDeleted, true)
        XCTAssertEqual(purgedIDs, [successfulID, failedID])
        XCTAssertTrue(store.permanentDeletionInProgressIDs.isEmpty)
    }

    private func temporaryDirectory(fileManager: FileManager) -> URL {
        fileManager.temporaryDirectory.appendingPathComponent(
            "PrimuseTVTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }

    private func deletedSource(id: String) -> MusicSource {
        let deletedAt = Date(timeIntervalSince1970: 2_000_000)
        return MusicSource(
            id: id,
            name: id,
            type: .googleDrive,
            authType: .oauth,
            modifiedAt: deletedAt,
            isDeleted: true,
            deletedAt: deletedAt
        )
    }
}

private actor ControlledSourceCredentialPurger {
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var resultContinuation: CheckedContinuation<Bool, Never>?

    func purge(_ source: MusicSource) async -> Bool {
        _ = source.id
        started = true
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume() }
        return await withCheckedContinuation { continuation in
            resultContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func finish(with result: Bool) {
        resultContinuation?.resume(returning: result)
        resultContinuation = nil
    }

}

private actor SequencedSourceCredentialPurger {
    private var results: [Bool]

    init(results: [Bool]) {
        self.results = results
    }

    func purge(_ source: MusicSource) -> Bool {
        _ = source.id
        return results.isEmpty ? true : results.removeFirst()
    }
}

private actor RecordingSourceCredentialPurger {
    private let failedIDs: Set<String>
    private var recordedIDs: Set<String> = []

    init(failedIDs: Set<String>) {
        self.failedIDs = failedIDs
    }

    func purge(_ source: MusicSource) -> Bool {
        recordedIDs.insert(source.id)
        return !failedIDs.contains(source.id)
    }

    func purgedIDs() -> Set<String> {
        recordedIDs
    }
}

private enum SourcesStoreDurabilityTestError: Error, Equatable {
    case injectedWriteFailure
}

@MainActor
final class TVLibraryBrowsePerformancePolicyTests: XCTestCase {
    func testOnlyRecommendationTabStartsRecommendationWork() {
        for filter in TVLibraryView.Filter.allCases where filter != .recommendations {
            XCTAssertFalse(
                TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: filter),
                filter.rawValue
            )
        }
        XCTAssertTrue(
            TVLibraryBackgroundWorkPolicy.refreshesRecommendations(for: .recommendations)
        )
    }

    func testSongArtworkPaletteUpdatesCoalesceWithoutInvalidatingOtherScopes() async throws {
        let store = TVStore()
        let initialPaletteRevisions = store.artworkPalettePublicationRevisions
        let initialRecommendationRevision = store.recommendationRevision

        for index in 0..<100 {
            let component = Double(index) / 100
            store.applyArtworkPalette(
                TVArtworkPalette(
                    primary: .init(red: component, green: 0.4, blue: 0.6),
                    secondary: .init(red: 0.2, green: component, blue: 0.3)
                ),
                forSongID: "palette-test-\(index)"
            )
        }
        try await Task.sleep(for: .milliseconds(250))

        let publishedPaletteRevisions = store.artworkPalettePublicationRevisions
        XCTAssertEqual(publishedPaletteRevisions.song, initialPaletteRevisions.song + 1)
        XCTAssertEqual(publishedPaletteRevisions.album, initialPaletteRevisions.album)
        XCTAssertEqual(store.recommendationRevision, initialRecommendationRevision)
    }

    func testPlaylistArtworkMaterializationHasFixedUpperBound() {
        XCTAssertEqual(TVStore.playlistArtworkCandidateLimit, 16)
    }

    func testLargePlaylistArtworkAccumulatorKeepsLateArtworkWithinBound() {
        let lastSongID = "playlist-song-25612"
        var accumulator = PlaylistBrowseArtworkAccumulator(
            playlistID: "large-playlist",
            limit: 16
        )

        for index in 0..<25_613 {
            accumulator.consider(
                Song(
                    id: "playlist-song-\(index)",
                    title: "Song \(index)",
                    fileFormat: .mp3,
                    filePath: "Music/song-\(index).mp3",
                    sourceID: "large-library",
                    coverArtFileName: index == 25_612 ? "late-cover.jpg" : nil
                )
            )
        }

        XCTAssertEqual(accumulator.visibleCount, 25_613)
        XCTAssertLessThanOrEqual(accumulator.artworkCandidates.count, 16)
        XCTAssertTrue(accumulator.artworkCandidates.contains { $0.id == lastSongID })
    }

    func testRemoteSmartPlaylistRevisionAdvancesOnlyForActualChanges() async throws {
        let fileManager = FileManager.default
        let storageDirectory = fileManager.temporaryDirectory.appendingPathComponent(
            "PrimuseTVSmartPlaylistTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: storageDirectory,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: storageDirectory) }

        let library = MusicLibrary(storageDirectory: storageDirectory)
        let initialRevision = library.playlistCollectionRevision
        let original = SmartPlaylist(
            id: "remote-smart-playlist",
            name: "Original",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )

        library.applyRemoteSmartPlaylist(original)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 1)
        XCTAssertEqual(library.smartPlaylists, [original])

        library.applyRemoteSmartPlaylist(original)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 1)
        XCTAssertEqual(library.smartPlaylists, [original])

        var changed = original
        changed.name = "Changed"
        changed.updatedAt = Date(timeIntervalSince1970: 2)
        library.applyRemoteSmartPlaylist(changed)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 2)
        XCTAssertEqual(library.smartPlaylists, [changed])

        library.applyRemoteSmartPlaylist(changed)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 2)
        XCTAssertEqual(library.smartPlaylists, [changed])

        library.deleteSmartPlaylistFromRemote(id: changed.id)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 3)
        XCTAssertTrue(library.smartPlaylists.isEmpty)

        library.deleteSmartPlaylistFromRemote(id: changed.id)
        XCTAssertEqual(library.playlistCollectionRevision, initialRevision + 3)
        XCTAssertTrue(library.smartPlaylists.isEmpty)

        _ = await library.persistNowAndWait()
    }
}

final class TVImmersiveDirectionalCommandTests: XCTestCase {
    func testHiddenCanvasUsesLeftAndRightForTrackNavigation() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .left,
                at: 10,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .previousTrack
        )
        XCTAssertEqual(
            state.action(
                for: .right,
                at: 11,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .nextTrack
        )
    }

    func testContinuousDirectionalEventsProduceOnlyOneTrackChange() {
        var state = TVImmersiveDirectionalCommandState(quietInterval: 0.45)

        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20), .nextTrack)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.10), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.30), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 20.50), .none)
        XCTAssertEqual(hiddenAction(&state, input: .right, at: 21.00), .nextTrack)
    }

    func testVisibleControlsAndModePickerKeepStandardFocusNavigation() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .left,
                at: 1,
                controlsVisible: true,
                modePickerVisible: false,
                assistiveNavigationEnabled: false
            ),
            .standardNavigation
        )
        XCTAssertEqual(
            state.action(
                for: .right,
                at: 2,
                controlsVisible: false,
                modePickerVisible: true,
                assistiveNavigationEnabled: false
            ),
            .standardNavigation
        )
    }

    func testAssistiveNavigationRevealsControlsWithoutChangingTrack() {
        var state = TVImmersiveDirectionalCommandState()

        XCTAssertEqual(
            state.action(
                for: .right,
                at: 1,
                controlsVisible: false,
                modePickerVisible: false,
                assistiveNavigationEnabled: true
            ),
            .revealControls
        )
        XCTAssertEqual(hiddenAction(&state, input: .down, at: 2), .revealControls)
    }

    func testReduceMotionUsesNearInstantChromeTransition() {
        XCTAssertEqual(
            TVImmersiveChromeMotionPolicy.duration(0.4, reduceMotion: true),
            0.01,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            TVImmersiveChromeMotionPolicy.duration(0.4, reduceMotion: false),
            0.4,
            accuracy: 0.0001
        )
    }

    private func hiddenAction(
        _ state: inout TVImmersiveDirectionalCommandState,
        input: TVImmersiveDirectionalInput,
        at uptime: TimeInterval
    ) -> TVImmersiveDirectionalAction {
        state.action(
            for: input,
            at: uptime,
            controlsVisible: false,
            modePickerVisible: false,
            assistiveNavigationEnabled: false
        )
    }
}

final class TVImmersivePresentationActivityTests: XCTestCase {
    func testQueueCoverPausesAndResumesRendering() {
        var activity = TVImmersivePresentationActivity()
        activity.handle(.appeared)
        XCTAssertTrue(activity.isMounted)
        XCTAssertTrue(activity.isRenderingActive)

        activity.handle(.queuePresented)
        XCTAssertTrue(activity.isMounted)
        XCTAssertFalse(activity.isRenderingActive)

        activity.handle(.queueDismissed)
        XCTAssertTrue(activity.isRenderingActive)
    }

    func testDismissalCannotBeReactivatedByLateQueueCallback() {
        var activity = TVImmersivePresentationActivity()
        activity.handle(.appeared)
        activity.handle(.queuePresented)
        activity.handle(.dismissalRequested)
        activity.handle(.queueDismissed)

        XCTAssertFalse(activity.isMounted)
        XCTAssertFalse(activity.isRenderingActive)
    }

    func testTypographyAndSpectrumEffectsShareTheSameRenderingGate() {
        for effect in [
            FullscreenPlayerEffect.kineticTitle,
            .radialPulse,
            .liveWaveform,
        ] {
            var activity = TVImmersivePresentationActivity()
            activity.handle(.appeared)
            XCTAssertTrue(activity.isRenderingActive, effect.rawValue)
            activity.handle(.disappeared)
            XCTAssertFalse(activity.isRenderingActive, effect.rawValue)
        }
    }
}

final class TVTrackNavigationAvailabilityTests: XCTestCase {
    func testEmptyQueueDisablesRemotePreviousAndNext() {
        XCTAssertEqual(
            availability(hasNowPlaying: true, queueCount: 0, currentIndex: 0),
            .unavailable
        )
    }

    func testSingleTrackKeepsPreviousRestartButDisablesNext() {
        XCTAssertEqual(
            availability(queueCount: 1, currentIndex: 0, available: [0]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: false)
        )
    }

    func testNextSkipsUnavailableQueueEntries() {
        XCTAssertEqual(
            availability(queueCount: 4, currentIndex: 0, available: [0, 3]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
    }

    func testRepeatAllEnablesWrappedNext() {
        XCTAssertEqual(
            availability(queueCount: 3, currentIndex: 2, wrapsNext: true, available: [0, 2]),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
    }

    func testLiveRadioRequiresAnotherValidStation() {
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: true, radioStationCount: 1),
            .unavailable
        )
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: true, radioStationCount: 2),
            TVTrackNavigationAvailability(canGoPrevious: true, canGoNext: true)
        )
        XCTAssertEqual(
            availability(isLiveRadio: true, hasCurrentRadioStation: false, radioStationCount: 2),
            .unavailable
        )
    }

    func testMusicVideoUsesTheSameQueueNavigationSemantics() {
        let videoQueueAvailability = availability(
            queueCount: 2,
            currentIndex: 0,
            available: [0, 1]
        )
        XCTAssertTrue(videoQueueAvailability.canGoPrevious)
        XCTAssertTrue(videoQueueAvailability.canGoNext)
    }

    private func availability(
        hasNowPlaying: Bool = true,
        isLiveRadio: Bool = false,
        hasCurrentRadioStation: Bool = false,
        radioStationCount: Int = 0,
        queueCount: Int = 0,
        currentIndex: Int = 0,
        wrapsNext: Bool = false,
        available: Set<Int> = []
    ) -> TVTrackNavigationAvailability {
        TVTrackNavigationAvailabilityPolicy.availability(
            hasNowPlaying: hasNowPlaying,
            isLiveRadio: isLiveRadio,
            hasCurrentRadioStation: hasCurrentRadioStation,
            radioStationCount: radioStationCount,
            queueCount: queueCount,
            currentIndex: currentIndex,
            wrapsNext: wrapsNext,
            isQueueItemAvailable: available.contains
        )
    }
}

final class TVLyricSyllableTimingTests: XCTestCase {
    func testConversionKeepsMixedPersianAndEnglishRowsInTheirOwnDirection() throws {
        let source = LyricsContentParser.parse("""
        [la:fa-IR]
        [00:01.00]<00:01.00>این <00:01.30>فارسی
        [00:03.00]<00:03.00>English <00:03.40>chorus
        [00:05.00]<00:05.00>سلام <00:05.40>OpenAI
        [00:07.00]<00:07.00>OpenAI <00:07.40>سلام
        """)
        let lines = TVPlaybackCoordinator.toTVLyrics(source, duration: 0)

        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines[0].writingDirection, .rightToLeft)
        XCTAssertEqual(lines[1].writingDirection, .leftToRight)
        XCTAssertEqual(lines[2].writingDirection, .rightToLeft)
        XCTAssertEqual(lines[3].writingDirection, .leftToRight)
    }

    func testConversionPreservesAbsoluteELRCTimestampsAndProvenance() throws {
        let sourceLine = try XCTUnwrap(
            LyricsContentParser.parse(
                "[00:29.30]<00:29.30>انتظار <00:29.60>و <00:31.30>انتظار"
            ).first
        )
        let line = try XCTUnwrap(
            TVPlaybackCoordinator.toTVLyrics([sourceLine], duration: 0).first
        )

        XCTAssertEqual(line.syllables.count, 3)
        XCTAssertEqual(line.syllables[0].start, 29.30, accuracy: 0.001)
        XCTAssertEqual(line.syllables[0].end, 29.60, accuracy: 0.001)
        XCTAssertEqual(line.syllables[1].start, 29.60, accuracy: 0.001)
        XCTAssertEqual(line.syllables[1].end, 31.30, accuracy: 0.001)
        XCTAssertEqual(line.syllables[1].endTiming, .inferred)
    }

    func testOrdinaryPlayerStopsSweepingDuringInferredSilentGap() throws {
        let syllables = try issue68Syllables()

        let halfwayThroughConjunction = TVSyllableHighlightPolicy.state(
            in: syllables,
            at: 29.81
        )
        XCTAssertEqual(halfwayThroughConjunction.index, 1)
        XCTAssertEqual(halfwayThroughConjunction.progress, 0.5, accuracy: 0.001)

        let earlyGap = TVSyllableHighlightPolicy.state(in: syllables, at: 30.10)
        let lateGap = TVSyllableHighlightPolicy.state(in: syllables, at: 31.00)
        XCTAssertEqual(earlyGap, TVSyllableHighlightState(index: 2, progress: 0))
        XCTAssertEqual(lateGap, earlyGap)
    }

    func testImmersiveHighlightRemainsStableDuringInferredSilentGap() throws {
        let syllables = try issue68Syllables().map(\.lyricSyllable)

        let earlyGap = ImmersiveLyricHighlightProgressPolicy.progress(
            in: syllables,
            at: 30.10
        )
        let lateGap = ImmersiveLyricHighlightProgressPolicy.progress(
            in: syllables,
            at: 31.00
        )

        XCTAssertGreaterThan(earlyGap, 0)
        XCTAssertLessThan(earlyGap, 1)
        XCTAssertEqual(lateGap, earlyGap, accuracy: 0.000_001)
    }

    func testExplicitHeldSyllableKeepsItsFullDuration() {
        let held = TVSyllable(
            w: "آواز",
            start: 10,
            end: 12.4,
            endTiming: .explicit
        )

        let state = TVSyllableHighlightPolicy.state(in: [held], at: 11.2)

        XCTAssertEqual(state.index, 0)
        XCTAssertEqual(state.progress, 0.5, accuracy: 0.001)
    }

    private func issue68Syllables() throws -> [TVSyllable] {
        let sourceLine = try XCTUnwrap(
            LyricsContentParser.parse(
                "[00:29.30]<00:29.30>انتظار <00:29.60>و <00:31.30>انتظار"
            ).first
        )
        return try XCTUnwrap(
            TVPlaybackCoordinator.toTVLyrics([sourceLine], duration: 0).first
        ).syllables
    }
}
#endif
