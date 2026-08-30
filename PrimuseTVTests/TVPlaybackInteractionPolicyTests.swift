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
#endif
