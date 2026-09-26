#if os(tvOS)
import Foundation
import AVFoundation
import CloudKit
import CryptoKit
import PrimuseKit
import XCTest
import UIKit
import SwiftUI
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

    func testSeekingFromLibraryKeepsProgressFocusWhenPlayerAppears() {
        var state = TVContentFocusRoutingState()
        _ = state.moveDown(from: .library, nowPlayingMode: .song)
        XCTAssertEqual(state.seekInNowPlaying(mode: .song)?.target, .nowPlaying(.scrubber))
        XCTAssertEqual(
            state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song)?.target,
            .nowPlaying(.scrubber)
        )
        state.returnToTabs()
        XCTAssertNil(state.contentDidAppear(in: .nowPlaying, nowPlayingMode: .song))
    }

    func testLiveRadioAndEmptyPlaybackCannotEnterSeeking() {
        var state = TVContentFocusRoutingState()
        XCTAssertNil(state.seekInNowPlaying(mode: .liveRadio))
        XCTAssertNil(state.seekInNowPlaying(mode: .empty))
        _ = state.seekInNowPlaying(mode: .song)
        XCTAssertEqual(
            state.contentModeDidChange(in: .nowPlaying, nowPlayingMode: .liveRadio)?.target,
            .nowPlaying(.liveRadioPrimary)
        )
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
    func testEnteringTabBarFromContentRedirectsOtherTabToActiveTab() {
        XCTAssertEqual(
            TVTabBarEntryFocusPolicy.correctedTarget(
                previous: nil,
                focused: .tab(.home),
                active: .sources
            ),
            .tab(.sources)
        )
    }

    func testEnteringTabBarFromContentRedirectsSettingsToActiveTab() {
        XCTAssertEqual(
            TVTabBarEntryFocusPolicy.correctedTarget(
                previous: nil,
                focused: .settings,
                active: .library
            ),
            .tab(.library)
        )
    }

    func testFocusAlreadyInsideTabBarKeepsHorizontalNavigation() {
        XCTAssertNil(
            TVTabBarEntryFocusPolicy.correctedTarget(
                previous: .tab(.library),
                focused: .tab(.nowPlaying),
                active: .library
            )
        )
        XCTAssertNil(
            TVTabBarEntryFocusPolicy.correctedTarget(
                previous: .tab(.search),
                focused: .settings,
                active: .search
            )
        )
    }

    func testEnteringCurrentTabNeedsNoCorrection() {
        XCTAssertNil(
            TVTabBarEntryFocusPolicy.correctedTarget(
                previous: nil,
                focused: .tab(.playlists),
                active: .playlists
            )
        )
    }

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

    func testForegroundAndExternalPlaybackCommandsUseTheirNativeOwners() {
        XCTAssertEqual(
            TVPlaybackCommandRoutingPolicy.foregroundOwner,
            .swiftUIForeground
        )
        XCTAssertEqual(
            TVPlaybackCommandRoutingPolicy.externalOwner,
            .mediaRemoteCommandCenter
        )
    }
}

final class TVLyricsLoadingPolicyTests: XCTestCase {
    func testSubsonicFamilyLoadsLyricsFromServerAPI() {
        for sourceType in [
            MusicSourceType.subsonic,
            .navidrome,
            .airsonic,
            .gonic,
        ] {
            XCTAssertEqual(
                TVLyricsLoadingPolicy.strategy(for: sourceType),
                .subsonicServer
            )
        }
    }

    func testOtherLyricsSourcesKeepTheirExistingRoutes() {
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .fnMusic), .fnMusicService)
        XCTAssertEqual(TVLyricsLoadingPolicy.strategy(for: .smb), .sourceFile)
    }
}

@MainActor
final class TVSourceLocalLibraryPolicyTests: XCTestCase {
    func testAddableTypesAreExactlyTheSelfScanningSet() {
        // 能在电视上添加的类型就是电视能自己建库的那一组,两份清单不能各改各的。
        XCTAssertEqual(Set(TVStore.addableTypes).count, TVStore.addableTypes.count)
        XCTAssertEqual(Set(TVStore.addableTypes), TVSourceLocalLibraryPolicy.directScanTypes)
        XCTAssertTrue(TVStore.addableTypes.contains(.synologyAudioStation))
        for type in TVStore.addableTypes where !type.isAwaitingPublicAPI {
            XCTAssertTrue(TVStore.canBuildLibraryOnTV(type), type.rawValue)
            XCTAssertEqual(TVSourceLocalLibraryPolicy.capability(for: type), .directScan)
        }
    }

    func testLibraryOnlySourcesRequirePairedLibrary() {
        for type in [MusicSourceType.local, .appleMusic, .appleMusicLibrary] {
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
        for type in TVStore.addableTypes where !type.isAwaitingPublicAPI {
            XCTAssertEqual(
                TVSourceSaveContinuationPolicy.destination(isNewSource: true, type: type),
                .scan,
                type.rawValue
            )
        }
        XCTAssertEqual(
            TVSourceSaveContinuationPolicy.destination(isNewSource: false, type: .smb),
            .sources
        )
        // 厂商接口还没开放的类型建不了库,新建后回到音乐源列表。
        XCTAssertEqual(
            TVSourceSaveContinuationPolicy.destination(isNewSource: true, type: .ugreen),
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
final class TVFnConnectCredentialTests: XCTestCase {
    func testDraftAccessCodeOverridesStoredCodesWithoutSaving() throws {
        let source = MusicSource(id: "fn-draft-\(UUID().uuidString)", name: "FN", type: .fnMusic,
                                 host: "livingroom-nas", fnMusicConnectionMode: .fnConnect,
                                 username: "listener")
        defer { _ = TVCredentialStore.clearLocalCredential(sourceID: source.id) }
        XCTAssertTrue(TVCredentialStore.replaceLocalCredential(
            sourceID: source.id, username: "listener", password: "saved-password",
            accessCode: "saved-code"
        ))
        let key = FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey
        let bundle = CredentialBundle(entries: [source.id: CredentialEntry(
            password: "bundle-password", extra: [key: "bundle-code"]
        )])
        let draft = TVCredentialStore.credential(
            for: source, bundle: bundle, password: "draft-password", fnConnectAccessCode: "draft-code"
        )
        XCTAssertEqual(draft.password, "draft-password")
        XCTAssertEqual(draft.extra[key], "draft-code")
        let saved = try XCTUnwrap(TVCredentialStore.loadLocalCredential(sourceID: source.id))
        XCTAssertEqual(saved.password, "saved-password")
        XCTAssertEqual(saved.accessCode, "saved-code")
    }

    func testLocalAccessCodeWinsOverOlderBundleAndBlankDraft() {
        let source = MusicSource(id: "fn-local-\(UUID().uuidString)", name: "FN", type: .fnMusic,
                                 host: "livingroom-nas", fnMusicConnectionMode: .fnConnect)
        defer { _ = TVCredentialStore.clearLocalCredential(sourceID: source.id) }
        XCTAssertTrue(TVCredentialStore.replaceLocalCredential(
            sourceID: source.id, username: "listener", password: "local-password",
            accessCode: "new-code"
        ))
        let key = FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey
        let bundle = CredentialBundle(entries: [source.id: CredentialEntry(extra: [key: "old-code"])])
        let credential = TVCredentialStore.credential(
            for: source, bundle: bundle, password: "", fnConnectAccessCode: ""
        )
        XCTAssertEqual(credential.password, "local-password")
        XCTAssertEqual(credential.extra[key], "new-code")
    }

    func testBundleAccessCodeSurvivesLANProjectionWithoutLocalCode() {
        var source = MusicSource(id: "fn-bundle-\(UUID().uuidString)", name: "FN", type: .fnMusic,
                                 username: "listener")
        source.connectionConfiguration = SourceConnectionConfiguration(
            localEndpoint: SourceConnectionEndpoint(host: "192.168.50.20", port: 5666, useSsl: false),
            remoteAccessMode: .vendor, vendorIdentifier: "livingroom-nas"
        )
        source = source.projectingPreferredConnectionForLegacy()
        XCTAssertEqual(source.effectiveFnMusicConnectionMode, .address)
        let key = FnMusicAPIProtocol.fnConnectAccessCodeCredentialKey
        let bundle = CredentialBundle(entries: [source.id: CredentialEntry(
            password: "bundle-password", extra: [key: "bundle-code"]
        )])
        let credential = TVCredentialStore.credential(for: source, bundle: bundle)
        XCTAssertEqual(credential.password, "bundle-password")
        XCTAssertEqual(credential.extra[key], "bundle-code")
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
            .spectrumHorizon,
            .particleBloom,
        ] {
            var activity = TVImmersivePresentationActivity()
            activity.handle(.appeared)
            XCTAssertTrue(activity.isRenderingActive, effect.rawValue)
            activity.handle(.disappeared)
            XCTAssertFalse(activity.isRenderingActive, effect.rawValue)
        }
    }
}

final class TVImmersiveScreenWakePolicyTests: XCTestCase {
    func testActiveImmersivePresentationKeepsDisplayAwake() {
        XCTAssertTrue(TVImmersiveScreenWakePolicy.shouldHoldLease(
            isMounted: true,
            sceneIsActive: true
        ))
    }

    func testInactiveOrDismissedPresentationReleasesDisplayWakeLease() {
        XCTAssertFalse(TVImmersiveScreenWakePolicy.shouldHoldLease(
            isMounted: false,
            sceneIsActive: true
        ))
        XCTAssertFalse(TVImmersiveScreenWakePolicy.shouldHoldLease(
            isMounted: true,
            sceneIsActive: false
        ))
    }

    func testQueueCoverKeepsImmersiveDisplayWakeLease() {
        var activity = TVImmersivePresentationActivity()
        activity.handle(.appeared)
        activity.handle(.queuePresented)

        XCTAssertTrue(TVImmersiveScreenWakePolicy.shouldHoldLease(
            isMounted: activity.isMounted,
            sceneIsActive: true
        ))
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

    func testConversionNestsBackingVocalsInsteadOfAddingRows() throws {
        let source = LyricsContentParser.parse("""
        <tt xmlns="http://www.w3.org/ns/ttml" xmlns:ttm="http://www.w3.org/ns/ttml#metadata">
          <body><div>
            <p begin="00:00:10.000" end="00:00:13.000" ttm:agent="v1">
              <span begin="00:00:10.000" end="00:00:10.600">Lead</span>
              <span begin="00:00:10.600" end="00:00:13.000"> line</span>
              <span ttm:role="x-bg" begin="00:00:11.000" end="00:00:12.000">
                <span begin="00:00:11.000" end="00:00:11.500">Back</span>
                <span begin="00:00:11.500" end="00:00:12.000">ing</span>
              </span>
            </p>
          </div></body>
        </tt>
        """)
        let lines = TVPlaybackCoordinator.toTVLyrics(source, duration: 0)

        // A backing group must not become a row of its own: it overlaps the
        // lead line and would take the current-row position from it.
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Lead line")
        XCTAssertEqual(lines[0].background.count, 1)
        XCTAssertEqual(lines[0].background[0].text, "Backing")
        XCTAssertEqual(lines[0].background[0].time, 11, accuracy: 0.001)
        XCTAssertEqual(lines[0].background[0].syllables.count, 2)
        XCTAssertEqual(lines[0].background[0].syllables[0].start, 11, accuracy: 0.001)
        XCTAssertTrue(lines[0].background[0].background.isEmpty)
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

@MainActor
final class TVRemoteTransportCoordinatorTests: XCTestCase {
    func testDisabledAndDetachedScopesDropPendingCommands() {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let coordinator = TVRemoteTransportCoordinator()
        var commands: [TVRemoteTransportCommand] = []
        let record: (TVRemoteTransportCommand) -> Void = { commands.append($0) }
        coordinator.configure(enabled: true, onCommand: record)
        coordinator.attach(to: controller)
        coordinator.perform(.nextTrack)

        coordinator.configure(enabled: false, onCommand: record)
        coordinator.perform(.seek)
        XCTAssertFalse(coordinator.longPress.isEnabled)
        coordinator.configure(enabled: true, onCommand: record)
        coordinator.perform(.togglePlayback)
        coordinator.detach()
        coordinator.perform(.nextTrack)

        XCTAssertEqual(commands, [.nextTrack, .togglePlayback])
        XCTAssertNil(coordinator.doublePress.view)
    }

    func testChangingOwnerMovesRecognizersWithoutDuplicatingThem() {
        let first = UIViewController()
        let second = UIViewController()
        let coordinator = TVRemoteTransportCoordinator()
        coordinator.configure(enabled: true) { _ in }
        coordinator.attach(to: first)
        coordinator.attach(to: first)
        XCTAssertEqual(first.view.gestureRecognizers?.count, 3)

        coordinator.attach(to: second)
        XCTAssertTrue(first.view.gestureRecognizers?.isEmpty ?? true)
        XCTAssertEqual(second.view.gestureRecognizers?.count, 3)
        XCTAssertTrue(coordinator.singlePress.view === second.view)
        coordinator.detach()
    }

    func testPresentedModalBlocksCommandsUntilDismissed() async {
        let controller = UIViewController()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true }
        let coordinator = TVRemoteTransportCoordinator()
        var commands: [TVRemoteTransportCommand] = []
        coordinator.configure(enabled: true) { commands.append($0) }
        coordinator.attach(to: controller)
        await withCheckedContinuation { continuation in
            controller.present(UIViewController(), animated: false) { continuation.resume() }
        }
        XCTAssertNotNil(controller.presentedViewController)
        coordinator.perform(.nextTrack)
        XCTAssertTrue(commands.isEmpty)

        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
        XCTAssertNil(controller.presentedViewController)
        coordinator.perform(.seek)
        XCTAssertEqual(commands, [.seek])
        coordinator.detach()
    }
}

@MainActor
final class TVRemoteSeekFocusTests: XCTestCase {
    func testSeekCommandFocusesPlayerProgressWithoutChangingTrack() async throws {
        try await verifySeekFocus { store in TVRoot().environment(store) }
    }

    func testSeekCommandRevealsAndFocusesImmersiveProgress() async throws {
        try await verifySeekFocus { store in TVImmersivePlayerView().environment(store) }
    }

    private func verifySeekFocus<Content: View>(@ViewBuilder content: (TVStore) -> Content) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "TVRemoteSeekFocusTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(FullscreenPlayerEffect.coverFlow.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        let store = TVStore(
            sourcesStore: SourcesStore(storageDirectoryURL: directory),
            library: MusicLibrary(storageDirectory: directory), defaults: defaults,
            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        )
        store.nowPlaying.songID = "seek-focus"
        store.nowPlaying.title = "Seek Focus"
        store.nowPlaying.duration = 180
        store.hasNowPlaying = true
        let host = UIHostingController(rootView: content(store)
            .environment(\.scenePhase, .active).defaultAppStorage(defaults)
            .environment(MusicIntelligenceService())
            .environment(TVThemeState.shared).environment(TVAppearanceState()))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previousWindow?.makeKeyAndVisible()
            defaults.removePersistentDomain(forName: defaultsName)
        }
        var coordinator: TVRemoteTransportCoordinator?
        for _ in 0..<80 {
            coordinator = host.view.gestureRecognizers?.compactMap {
                $0.delegate as? TVRemoteTransportCoordinator
            }.first(where: { $0.enabled })
            if coordinator != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try XCTUnwrap(coordinator).perform(.seek)
        let minimumScrubberWidth = host.view.bounds.width * 0.25
        var focusedFrame = CGRect.zero
        for _ in 0..<80 {
            focusedFrame = UIFocusSystem(for: host.view)?.focusedItem?.frame ?? .zero
            if focusedFrame.width > minimumScrubberWidth && (20...80).contains(focusedFrame.height) { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(250))
        focusedFrame = UIFocusSystem(for: host.view)?.focusedItem?.frame ?? .zero
        let attachment = XCTAttachment(image: UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        })
        attachment.name = "SeekFocus"
        attachment.lifetime = .keepAlways
        add(attachment)
        // SwiftUI exposes a UIFocusItem rather than a UIView; its wide, shallow
        // bounds distinguish the progress control from tabs and transport buttons.
        // Use the host width so different simulator display sizes remain valid.
        XCTAssertGreaterThan(focusedFrame.width, minimumScrubberWidth)
        XCTAssertTrue((20...80).contains(focusedFrame.height), "Unexpected focused frame: \(focusedFrame)")
        XCTAssertEqual(store.nowPlaying.songID, "seek-focus")
        XCTAssertEqual(store.currentTime, 0)
    }
}

/// 可重放的伪随机源(splitmix64),让洗牌相关断言不依赖系统随机。
private struct TVSeededRandomNumberGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

final class TVPlaybackQueuePolicyTests: XCTestCase {
    func testShuffledSelectionPlaysSelectedSongFirstAndKeepsEveryOtherIndexOnce() {
        var generator = TVSeededRandomNumberGenerator(seed: 0xC0FFEE)
        let plan = TVPlaybackQueuePolicy.plan(
            count: 8,
            selectedIndex: 5,
            shuffled: true,
            using: &generator
        )

        XCTAssertEqual(plan.queueIndex, 0)
        XCTAssertEqual(plan.canonicalIndices.first, 5)
        XCTAssertEqual(plan.canonicalIndices.count, 8)
        XCTAssertEqual(Set(plan.canonicalIndices), Set(0..<8))
        XCTAssertEqual(plan.canonicalIndices.dropFirst().filter { $0 == 5 }.count, 0)
    }

    func testUnshuffledSelectionKeepsIdentityOrderAndStopsOnSelectedIndex() {
        var generator = TVSeededRandomNumberGenerator(seed: 7)
        let plan = TVPlaybackQueuePolicy.plan(
            count: 6,
            selectedIndex: 4,
            shuffled: false,
            using: &generator
        )

        XCTAssertEqual(plan.canonicalIndices, Array(0..<6))
        XCTAssertEqual(plan.queueIndex, 4)
    }

    func testUnshuffledWithoutSelectionStartsAtFirstEntry() {
        var generator = TVSeededRandomNumberGenerator(seed: 11)
        let plan = TVPlaybackQueuePolicy.plan(
            count: 3,
            selectedIndex: nil,
            shuffled: false,
            using: &generator
        )

        XCTAssertEqual(plan.canonicalIndices, [0, 1, 2])
        XCTAssertEqual(plan.queueIndex, 0)
    }

    func testShuffledWithoutSelectionKeepsPermutationAndStartsAtQueueHead() {
        var generator = TVSeededRandomNumberGenerator(seed: 42)
        let plan = TVPlaybackQueuePolicy.plan(
            count: 12,
            selectedIndex: nil,
            shuffled: true,
            using: &generator
        )

        XCTAssertEqual(plan.queueIndex, 0)
        XCTAssertEqual(plan.canonicalIndices.count, 12)
        XCTAssertEqual(plan.canonicalIndices.sorted(), Array(0..<12))
    }

    func testEmptyListProducesEmptyPlan() {
        var generator = TVSeededRandomNumberGenerator(seed: 1)
        let shuffledPlan = TVPlaybackQueuePolicy.plan(
            count: 0,
            selectedIndex: 0,
            shuffled: true,
            using: &generator
        )
        let orderedPlan = TVPlaybackQueuePolicy.plan(
            count: 0,
            selectedIndex: nil,
            shuffled: false,
            using: &generator
        )

        XCTAssertEqual(shuffledPlan, TVPlaybackQueuePolicy.Plan.empty)
        XCTAssertEqual(orderedPlan, TVPlaybackQueuePolicy.Plan.empty)
        XCTAssertTrue(shuffledPlan.canonicalIndices.isEmpty)
        XCTAssertEqual(shuffledPlan.queueIndex, 0)
    }

    func testOutOfRangeSelectionFallsBackToUnselectedBehaviour() {
        var generator = TVSeededRandomNumberGenerator(seed: 5)
        let orderedPlan = TVPlaybackQueuePolicy.plan(
            count: 4,
            selectedIndex: 9,
            shuffled: false,
            using: &generator
        )
        let shuffledPlan = TVPlaybackQueuePolicy.plan(
            count: 4,
            selectedIndex: -1,
            shuffled: true,
            using: &generator
        )

        XCTAssertEqual(orderedPlan.canonicalIndices, Array(0..<4))
        XCTAssertEqual(orderedPlan.queueIndex, 0)
        XCTAssertEqual(shuffledPlan.queueIndex, 0)
        XCTAssertEqual(shuffledPlan.canonicalIndices.sorted(), Array(0..<4))
    }

    func testSingleEntryListKeepsSelectedSongPlayable() {
        var generator = TVSeededRandomNumberGenerator(seed: 3)
        let plan = TVPlaybackQueuePolicy.plan(
            count: 1,
            selectedIndex: 0,
            shuffled: true,
            using: &generator
        )

        XCTAssertEqual(plan.canonicalIndices, [0])
        XCTAssertEqual(plan.queueIndex, 0)
    }

    func testSameSeedReproducesTheSameShuffledPlan() {
        var first = TVSeededRandomNumberGenerator(seed: 2_024)
        var second = TVSeededRandomNumberGenerator(seed: 2_024)
        let planA = TVPlaybackQueuePolicy.plan(
            count: 20,
            selectedIndex: 13,
            shuffled: true,
            using: &first
        )
        let planB = TVPlaybackQueuePolicy.plan(
            count: 20,
            selectedIndex: 13,
            shuffled: true,
            using: &second
        )

        XCTAssertEqual(planA, planB)
        XCTAssertEqual(planA.canonicalIndices.first, 13)
        // 洗牌必须真的改变顺序,否则「随机」只是原序。
        XCTAssertNotEqual(planA.canonicalIndices.dropFirst().map { $0 }, Array(0..<20).filter { $0 != 13 })
    }
}

@MainActor
final class TVDeviceRegressionTests: XCTestCase {
    func testLegacyMigrationOnlyAcceptsKnownDigestsAndSupportedProviderIdentities() {
        let path = "/music/Track.mp3"
        let digest = SHA256.hash(data: Data("nas:\(path)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        let songs = [
            Song(id: digest, title: "Path", fileFormat: .mp3, filePath: path, sourceID: "nas"),
            Song(id: String(repeating: "a", count: 64), title: "Provider", fileFormat: .mp3, filePath: path, sourceID: "fn"),
            Song(id: String(repeating: "b", count: 64), title: "Unrelated", fileFormat: .mp3, filePath: path, sourceID: "nas"),
            Song(id: String(repeating: "z", count: 64), title: "Opaque", fileFormat: .mp3, filePath: path, sourceID: "fn")
        ]
        let plan = TVStore.legacySongIDMigration(songs: songs, sourceTypes: ["nas": .webdav, "fn": .fnMusic])
        XCTAssertEqual(plan.replacements, [digest: String(digest.prefix(32)), String(repeating: "a", count: 64): String(repeating: "a", count: 32)])
        XCTAssertEqual(plan.sourceIDs, ["nas", "fn"])
    }

    func testBackgroundIDMigrationPreservesConcurrentEditsAndPlaylistMembership() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs((0..<1_000).map {
            Song(id: "old-\($0)", title: "Song \($0)", albumTitle: "Album", fileFormat: .mp3,
                 filePath: "/\($0).mp3", sourceID: "source")
        })
        await library.waitForPendingIndex()
        var duplicate = try XCTUnwrap(library.song(id: "old-0"))
        duplicate.id = "new-0"
        duplicate.title = "Duplicate canonical row"
        duplicate.filePath = "/canonical.mp3"
        library.addSongs([duplicate], pruneMissingSongs: false)
        await library.waitForPendingIndex()
        XCTAssertNotNil(library.song(id: "old-0"))
        let migration = Task { await library.remapSongIDsInBackground(["old-0": "new-0"]) }
        await Task.yield()
        var edited = try XCTUnwrap(library.song(id: "old-0"))
        edited.title = "Edited during migration"
        library.replaceSong(edited)
        library.setLiked(songID: edited.id, isLiked: true, propagatesServerMutation: false)
        library.recordPlayback(of: edited.id)
        library.updateLibraryReview(for: .song(edited.id), rating: 4, comment: "Retained")
        let migrated = await migration.value
        XCTAssertTrue(migrated)
        XCTAssertNil(library.song(id: "old-0"))
        XCTAssertEqual(library.song(id: "new-0")?.title, "Edited during migration")
        XCTAssertTrue(library.isLiked(songID: "new-0"))
        XCTAssertFalse(library.isLiked(songID: "old-0"))
        XCTAssertEqual(library.recentlyPlayedSongs(limit: 1).first?.id, "new-0")
        XCTAssertEqual(library.libraryReview(for: .song("new-0"))?.rating, 4)
        XCTAssertEqual(library.visibleSongs.count, 1_000)
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Migration persistence failed") }
        let reloaded = MusicLibrary(storageDirectory: directory)
        XCTAssertNil(reloaded.song(id: "old-0"))
        XCTAssertEqual(reloaded.song(id: "new-0")?.title, "Edited during migration")
        XCTAssertTrue(reloaded.isLiked(songID: "new-0"))
    }

    func testTVStartupMigrationRestoresCanonicalPausedSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: UUID().uuidString, name: "Migration", type: .fnMusic)
        try sources.addDurably(source)
        let legacyID = String(repeating: "a", count: 64)
        let canonicalID = String(legacyID.prefix(32))
        let original = Song(id: legacyID, title: "Retained", duration: 30, fileFormat: .mp3,
                            filePath: "/track.mp3", sourceID: source.id)
        var duplicate = original
        duplicate.id = canonicalID
        library.addSongs([original, duplicate])
        await library.waitForPendingIndex()
        library.setLiked(songID: legacyID, isLiked: true, propagatesServerMutation: false)
        let session = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        try session.save(.init(queueSongIDs: [legacyID], currentSongID: legacyID, currentIndex: 0,
                               currentTime: 7, duration: 30, wasPlaying: false, shuffleEnabled: false,
                               shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false))
        let store = TVStore(sourcesStore: sources, library: library, sessionStore: session)
        await store.prepareLocalLibrary()
        XCTAssertEqual(library.songs.map(\.id), [canonicalID])
        XCTAssertTrue(library.isLiked(songID: canonicalID))
        XCTAssertEqual(store.songIDs, [canonicalID])
        XCTAssertEqual(store.currentSongID, canonicalID)
        XCTAssertEqual(store.currentTime, 7, accuracy: 0.01)
        XCTAssertEqual(store.engine.status, .paused)
        XCTAssertFalse(store.engine.hasPreparedAudio)
        XCTAssertNil(store.playbackIssue)
        XCTAssertEqual(try session.load()?.currentSongID, canonicalID)
        _ = await library.persistNowAndWait()
    }

    func testRecentlyAddedAlbumsRefreshAfterEditsAndSourceVisibilityChanges() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: UUID().uuidString, name: "Recent", type: .fnMusic)
        try sources.addDurably(source)
        var older = Song(id: "older", title: "Older", albumTitle: "Older album", fileFormat: .mp3,
                         filePath: "/older/track.mp3", sourceID: source.id)
        older.dateAdded = Date(timeIntervalSince1970: 100)
        var newer = Song(id: "newer", title: "Newer", albumTitle: "Newer album", fileFormat: .mp3,
                         filePath: "/newer/track.mp3", sourceID: source.id)
        newer.dateAdded = Date(timeIntervalSince1970: 200)
        library.addSongs([older, newer])
        await library.waitForPendingIndex()
        let store = TVStore(sourcesStore: sources, library: library,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        store.reload(reloadLibrary: false)
        XCTAssertEqual(store.recentlyAddedAlbums.map(\.title), ["Newer album", "Older album"])
        var edited = try XCTUnwrap(library.song(id: older.id))
        edited.dateAdded = Date(timeIntervalSince1970: 300)
        library.replaceSong(edited)
        await library.waitForPendingIndex()
        store.reload(reloadLibrary: false)
        XCTAssertEqual(store.recentlyAddedAlbums.map(\.title), ["Older album", "Newer album"])
        store.setSourceEnabled(source.id, false)
        XCTAssertTrue(store.recentlyAddedAlbums.isEmpty)
        store.setSourceEnabled(source.id, true)
        XCTAssertEqual(store.recentlyAddedAlbums.map(\.title), ["Older album", "Newer album"])
        _ = await library.persistNowAndWait()
    }

    func testSearchSongPathRetainsSanitizationWhenPresentedOnDemand() {
        func song(path: String, sourceType: MusicSourceType = .navidrome) -> TVSong {
            TVSong(id: "path", albumID: "album", coverRef: nil, title: "Song", artist: "Artist",
                   duration: 30, format: "MP3", bitrate: 320, sampleRate: 44.1,
                   sourceID: "source", filePath: path, sourceType: sourceType, plays: 0, liked: false)
        }
        let remote = song(path: "https://user:password@example.com/Music/Hello%20World.mp3?token=secret#fragment")
        XCTAssertEqual(remote.displayPath, "/Music/Hello World.mp3")
        XCTAssertEqual(song(path: "/Music/token=secret/Song.mp3").displayPath, nil)
        XCTAssertNil(song(path: "opaque-item-id").displayPath)
        XCTAssertNil(song(path: "/Music/Song.mp3", sourceType: .appleMusic).displayPath)
    }

    func testListeningHistoryRefreshesSongCountsAndSmartPlaylistsWithoutRebuildingLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: "history-source", name: "History", type: .navidrome)
        try sources.addDurably(source)
        let song = Song(id: UUID().uuidString, title: "History", fileFormat: .mp3,
                        filePath: "/history.mp3", sourceID: source.id)
        library.addSongs([song])
        await library.waitForPendingIndex()
        library.applyRemoteSmartPlaylist(SmartPlaylist(id: "played", name: "Played",
            rules: [.init(field: .playCount, op: .greaterThan, value: "0")]))
        let store = TVStore(sourcesStore: sources, library: library,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        store.reload(reloadLibrary: false)
        try await Task.sleep(for: .milliseconds(100))
        let revision = store.recommendationRevision
        XCTAssertEqual(store.smartPlaylists.first?.count, 0)
        PlayHistoryStore.shared.record(song: song, startedAt: Date(), listenedSec: 35)
        for _ in 0..<1_000 {
            if store.song(song.id)?.plays == 1 { break }
            await Task.yield()
        }
        XCTAssertEqual(store.song(song.id)?.plays, 1)
        XCTAssertEqual(store.songs.first?.plays, 1)
        XCTAssertEqual(store.smartPlaylists.first?.count, 1)
        XCTAssertEqual(store.recommendationRevision, revision)
        _ = await library.persistNowAndWait()
    }

    func testDecodedPlaybackResumesAfterAudioSessionDeactivation() async throws {
        let file = TVDecodedTemporaryFilePolicy.makeURL(
            in: FileManager.default.temporaryDirectory, fileExtension: "caf"
        )
        defer { try? FileManager.default.removeItem(at: file) }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let audio = try AVAudioFile(forWriting: file, settings: format.settings)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 441_000))
            buffer.frameLength = buffer.frameCapacity
            for channel in 0..<2 {
                buffer.floatChannelData![channel].initialize(repeating: 0, count: Int(buffer.frameLength))
            }
            try audio.write(from: buffer)
        }
        let engine = TVAudioEngine()
        defer { engine.stop() }
        try engine.loadDecoded(fileURL: file, decoder: .ffmpeg, title: "Resume", artist: "", album: "", duration: 10)
        try await Task.sleep(for: .seconds(1))
        engine.pause()
        try await Task.sleep(for: .seconds(1))
        let paused = engine.currentTime
        XCTAssertTrue(engine.hasPreparedAudio)
        XCTAssertTrue(engine.play())
        try await Task.sleep(for: .seconds(1))
        XCTAssertGreaterThan(engine.currentTime, paused + 0.4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAlbumLookupReflectsOrderAndSourceVisibility() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: "album-source", name: "Albums", type: .fnMusic)
        try sources.addDurably(source)
        var second = Song(id: "second", title: "Second", albumTitle: "Album", fileFormat: .mp3,
                          filePath: "/second.mp3", sourceID: source.id)
        second.trackNumber = 2
        var first = second
        first.id = "first"; first.title = "First"; first.trackNumber = 1
        library.addSongs([second, first])
        await library.waitForPendingIndex()
        let store = TVStore(sourcesStore: sources, library: library,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        store.reload(reloadLibrary: false)
        let albumID = try XCTUnwrap(library.song(id: first.id)?.albumID)
        XCTAssertEqual(store.songs(forAlbum: albumID).map(\.id), ["first", "second"])
        let unchangedRevision = store.recommendationRevision
        store.reload(reloadLibrary: false)
        XCTAssertEqual(store.recommendationRevision, unchangedRevision,
                       "Unchanged source reloads must not rebuild the catalogue")
        store.setSourceEnabled(source.id, false)
        XCTAssertTrue(store.songs(forAlbum: albumID).isEmpty)
        store.setSourceEnabled(source.id, true)
        XCTAssertEqual(store.songs(forAlbum: albumID).map(\.id), ["first", "second"])
        var reordered = try XCTUnwrap(library.song(id: first.id))
        reordered.trackNumber = 3
        library.replaceSong(reordered)
        await library.waitForPendingIndex()
        store.reload(reloadLibrary: false)
        XCTAssertEqual(store.songs(forAlbum: albumID).map(\.id), ["second", "first"])
        _ = await library.persistNowAndWait()
    }

    func testBackgroundReloadReplaysEditsAndPublishesOnceReady() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        library.addSongs((0..<500).map {
            Song(id: "reload-\($0)", title: "Song \($0)", fileFormat: .mp3,
                 filePath: "/\($0).mp3", sourceID: "source")
        })
        await library.waitForPendingIndex()
        guard case .success = await library.persistNowAndWait() else { return XCTFail("Fixture persistence failed") }
        let reload = Task { await library.reloadFromDiskInBackground(preferExternalSnapshot: false) }
        for _ in 0..<1_000 {
            if !library.isReady { break }
            await Task.yield()
        }
        XCTAssertFalse(library.isReady)
        library.setLiked(songID: "reload-0", isLiked: true, propagatesServerMutation: false)
        await reload.value
        XCTAssertTrue(library.isReady)
        XCTAssertEqual(library.songs.count, 500)
        XCTAssertTrue(library.isLiked(songID: "reload-0"))
        _ = await library.persistNowAndWait()
    }

    func testMissingCredentialEndsLoadingAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: UUID().uuidString, name: "No credential", type: .fnMusic)
        try sources.addDurably(source)
        let song = Song(id: UUID().uuidString, title: "DTS", duration: 20, fileFormat: .dts,
                        filePath: "/tracks/test.dts", sourceID: source.id)
        library.addSongs([song])
        await library.waitForPendingIndex()
        let store = TVStore(sourcesStore: sources, library: library,
                            sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        store.reload(reloadLibrary: false)
        XCTAssertTrue(store.playResolvedQueue(songIDs: [song.id], shuffled: false, startingAt: song.id))
        for _ in 0..<100 {
            if store.playbackIssue != nil && !store.isLoading { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotNil(store.playbackIssue)
        XCTAssertFalse(store.isLoading)
        guard case .failed = store.engine.status else { return XCTFail("Resolution failure must be terminal") }
        store.togglePlayPause()
        XCTAssertTrue(store.isLoading, "One press retries a failed resolution")
        store.togglePlayPause()
        XCTAssertFalse(store.isLoading, "A second press cancels the pending request")
        _ = await library.persistNowAndWait()
    }

    func testRestoringPausedSelectionDoesNotResolveOrDownload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        let source = MusicSource(id: UUID().uuidString, name: "Deferred", type: .fnMusic)
        try sources.addDurably(source)
        let song = Song(id: UUID().uuidString, title: "Saved track", duration: 30, fileFormat: .dts,
                        filePath: "/tracks/deferred.dts", sourceID: source.id)
        library.addSongs([song])
        await library.waitForPendingIndex()
        let session = PlaybackSessionStore(url: directory.appendingPathComponent("session.json"))
        try session.save(.init(queueSongIDs: [song.id], currentSongID: song.id, currentIndex: 0,
                               currentTime: 7, duration: 30, wasPlaying: false, shuffleEnabled: false,
                               shuffledIndices: [], shufflePosition: 0, repeatMode: .off, isAtTrackEnd: false))
        let store = TVStore(sourcesStore: sources, library: library, sessionStore: session)
        store.reload(reloadLibrary: false)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(store.currentSongID, song.id)
        XCTAssertEqual(store.currentTime, 7, accuracy: 0.01)
        XCTAssertEqual(store.engine.status, .paused)
        XCTAssertNil(store.playbackIssue, "Restoring must not attempt credential resolution")
        XCTAssertFalse(store.engine.hasPreparedAudio)
        _ = await library.persistNowAndWait()
    }

    func testPreparedTVStartupFiltersOrphansWithoutRemovingCanonicalSongs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let original = MusicLibrary(storageDirectory: directory)
        original.addSongs([Song(id: "orphan", title: "Retained", fileFormat: .mp3,
                                filePath: "/song.mp3", sourceID: "missing-source")])
        await original.waitForPendingIndex()
        guard case .success = await original.persistNowAndWait() else { return XCTFail("Fixture persistence failed") }
        let prepared = await MusicLibrary.prepareStartup(knownSourceIDs: [], storageDirectory: directory)
        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        library.publish(prepared)
        XCTAssertTrue(library.visibleSongs.isEmpty)
        XCTAssertEqual(library.songs.map(\.id), ["orphan"])
        XCTAssertEqual(library.disabledSourceIDs, ["missing-source"])
    }

    private final class ExistingRecord: CKRecord, @unchecked Sendable {
        override var recordChangeTag: String? { "server-tag" }
    }

    func testDuplicateConstraintRequiresSameServerIdentityAndChangeTag() {
        let id = CKRecord.ID(recordName: "RadioStation/station", zoneID: .init(zoneName: "test"))
        let local = CKRecord(recordType: "RadioStation", recordID: id)
        let server = ExistingRecord(recordType: "RadioStation", recordID: id)
        let error = CKError(.constraintViolation, userInfo: [CKRecordChangedErrorServerRecordKey: server])
        XCTAssertNotNil(CloudKitSyncService.existingRecordConflict(error, local: local))
        XCTAssertNil(CloudKitSyncService.existingRecordConflict(CKError(.constraintViolation), local: local))
        let wrongType = CKRecord(recordType: "Playlist", recordID: id)
        XCTAssertNil(CloudKitSyncService.existingRecordConflict(error, local: wrongType))
        let wrongZone = CKRecord(recordType: "RadioStation", recordID: .init(recordName: id.recordName))
        XCTAssertNil(CloudKitSyncService.existingRecordConflict(error, local: wrongZone))
        let unversioned = CKError(.constraintViolation, userInfo: [CKRecordChangedErrorServerRecordKey: local])
        XCTAssertNil(CloudKitSyncService.existingRecordConflict(unversioned, local: local))
    }
}
#endif
