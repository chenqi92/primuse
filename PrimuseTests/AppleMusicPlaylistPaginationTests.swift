import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class AppleMusicLibraryReconciliationTests: XCTestCase {
    private let sourceID = AppleMusicLibraryService.systemSourceID
    private let mirrorID = AppleMusicLibraryService.systemPlaylistID

    private func song(_ id: String, sourceID: String? = nil) -> Song {
        Song(id: id, title: id, duration: 180, fileFormat: .mp3,
             filePath: id, sourceID: sourceID ?? self.sourceID)
    }

    private func withLibrary(
        _ body: (MusicLibrary, AppleMusicLibraryService) async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AppleMusicReconciliation-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults)
        await library.whenReady()
        library.updateAppleMusicSourceInstalled(true)
        let appleMusic = AppleMusicService(playbackSettings: PlaybackSettingsStore(), library: library)
        let service = AppleMusicLibraryService(library: library, appleMusic: appleMusic, defaults: defaults)
        try await body(library, service)
        await library.waitForPendingIndex()
        _ = await library.persistNowAndWait(materializePortableSnapshot: false)
    }

    private func commit(
        _ songs: [Song], to library: MusicLibrary, using service: AppleMusicLibraryService,
        completeDeviceLibrary: Bool = true
    ) async {
        let access = AppleMusicLibraryAccess(
            storefrontCountryCode: nil, canPlayCatalogContent: false, canBecomeSubscriber: true
        )
        let prepared = await library.prepareIncomingSongsOffMain(songs)
        service.commitLibrarySongs(
            prepared, librarySongIDs: songs.map(\.id),
            syncMode: access.syncMode(hasCompleteDeviceLibrary: completeDeviceLibrary)
        )
        await library.waitForPendingIndex()
    }

    func testSystemDeletionUpdatesSongsCountAndMirrorWithoutSubscription() async throws {
        try await withLibrary { library, service in
            let imported = [song("local-1"), song("local-2"), song("local-3")]
            let unrelated = song("nas-song", sourceID: "nas")
            library.addSongs([unrelated])
            await commit(imported, to: library, using: service)
            await commit([imported[2]], to: library, using: service)

            XCTAssertNil(library.song(id: imported[0].id))
            XCTAssertNil(library.song(id: imported[1].id))
            XCTAssertEqual(library.songCountsBySourceID()[sourceID], 1)
            XCTAssertEqual(library.rawSongIDs(forPlaylist: mirrorID), [imported[2].id])
            XCTAssertNotNil(library.song(id: unrelated.id))

            // A later re-import is allowed: reconciliation must not create a deletion tombstone.
            await commit(imported, to: library, using: service)
            XCTAssertEqual(library.songCountsBySourceID()[sourceID], 3)
        }
    }

    func testDeletingLastSystemSongClearsLibraryMirrorWithoutSubscription() async throws {
        try await withLibrary { library, service in
            await commit([song("last-local")], to: library, using: service)
            await commit([], to: library, using: service)
            XCTAssertEqual(library.songCountsBySourceID()[sourceID] ?? 0, 0)
            XCTAssertTrue(library.rawSongIDs(forPlaylist: mirrorID).isEmpty)
        }
    }

    func testSystemDeletionAlsoClearsLocallyRemovedEntries() async throws {
        try await withLibrary { library, service in
            let imported = [song("removed-1"), song("removed-2"), song("remaining")]
            await commit(imported, to: library, using: service)
            try library.removeSongsFromThisDevice(Array(imported.prefix(2)))
            XCTAssertEqual(library.locallyRemovedCount(forSourceID: sourceID), 2)
            await commit([imported[2]], to: library, using: service)
            XCTAssertEqual(library.locallyRemovedCount(forSourceID: sourceID), 0)
            XCTAssertEqual(library.rawSongIDs(forPlaylist: mirrorID), [imported[2].id])
        }
    }

    func testPartialFallbackStillPreservesExistingSongsAndMirror() async throws {
        try await withLibrary { library, service in
            let existing = [song("cloud-1"), song("local-2")]
            await commit(existing, to: library, using: service)
            await commit([existing[1]], to: library, using: service, completeDeviceLibrary: false)
            await commit([], to: library, using: service, completeDeviceLibrary: false)
            XCTAssertEqual(library.songCountsBySourceID()[sourceID], 2)
            XCTAssertEqual(library.rawSongIDs(forPlaylist: mirrorID), existing.map(\.id))
        }
    }
}

final class AppleMusicMediaLibraryGateTests: XCTestCase, @unchecked Sendable {
    private actor AccessProbe {
        var active = 0
        var maximumActive = 0
        var completed = 0

        func enter() {
            active += 1
            maximumActive = max(maximumActive, active)
        }

        func leave() {
            active -= 1
            completed += 1
        }
    }

    private enum ReadFailure: Error { case unavailable }

    private nonisolated static func synchronousRequestSetup(
        entered: XCTestExpectation,
        releasedBy semaphore: DispatchSemaphore
    ) -> (onMainThread: Bool, released: Bool) {
        let onMainThread = Thread.isMainThread
        entered.fulfill()
        // MusicKit can block synchronously before its asynchronous response begins.
        let released = semaphore.wait(timeout: .now() + 2) == .success
        return (onMainThread, released)
    }

    private nonisolated static func isRunningOnMainThread() -> Bool {
        Thread.isMainThread
    }

    @MainActor
    func testSynchronousRequestSetupKeepsMainActorResponsive() async {
        let entered = expectation(description: "Synchronous MusicKit setup started")
        let mainActorResponded = DispatchSemaphore(value: 0)
        let read = Task {
            await AppleMusicMediaLibraryGate.run {
                let setup = Self.synchronousRequestSetup(entered: entered, releasedBy: mainActorResponded)
                await MainActor.run { MainActor.preconditionIsolated() }
                return (setup.onMainThread, setup.released, Self.isRunningOnMainThread())
            }
        }
        await fulfillment(of: [entered], timeout: 3)
        MainActor.preconditionIsolated()
        mainActorResponded.signal()
        let (setupWasOnMainThread, respondedDuringSetup, resumedOnMainThread) = await read.value
        XCTAssertFalse(setupWasOnMainThread)
        XCTAssertTrue(respondedDuringSetup, "UI and sync timeout must run while MusicKit setup is blocked")
        XCTAssertFalse(resumedOnMainThread, "Progress reporting must not move subsequent pages onto the main thread")
    }

    func testSyncAndArtworkReadsRemainExclusiveWhileRequestsSuspend() async throws {
        let probe = AccessProbe()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    if index.isMultiple(of: 2) {
                        try await AppleMusicMediaLibraryGate.runOnMainActor {
                            MainActor.preconditionIsolated()
                            await probe.enter()
                            try await Task.sleep(for: .milliseconds(2))
                            MainActor.preconditionIsolated()
                            await probe.leave()
                        }
                    } else {
                        try await AppleMusicMediaLibraryGate.run {
                            await probe.enter()
                            try await Task.sleep(for: .milliseconds(2))
                            await probe.leave()
                        }
                    }
                }
            }
            try await group.waitForAll()
        }
        let maximum = await probe.maximumActive
        let completed = await probe.completed
        XCTAssertEqual(maximum, 1, "Suspended sync requests must exclude background artwork reads")
        XCTAssertEqual(completed, 24)
    }

    func testFailedSyncReleasesAccessForArtwork() async {
        do {
            try await AppleMusicMediaLibraryGate.run {
                await Task.yield()
                throw ReadFailure.unavailable
            }
            XCTFail("Expected the query error")
        } catch is ReadFailure { } catch { XCTFail("Unexpected error: \(error)") }
        let result = await AppleMusicMediaLibraryGate.run { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCancelledSyncReleasesAccessForArtwork() async {
        let entered = expectation(description: "Sync request entered the media library")
        let sync = Task {
            try await AppleMusicMediaLibraryGate.run {
                entered.fulfill()
                try await Task.sleep(for: .seconds(30))
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        sync.cancel()
        do {
            try await sync.value
            XCTFail("Expected cancellation")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        let result = await AppleMusicMediaLibraryGate.run { 42 }
        XCTAssertEqual(result, 42)
    }

    func testCancellationDuringSynchronousSetupDiscardsLateResponseAndReleasesAccess() async {
        let entered = expectation(description: "Synchronous request started")
        let finishSetup = DispatchSemaphore(value: 0)
        let sync = Task {
            try await AppleMusicMediaLibraryGate.run {
                _ = Self.synchronousRequestSetup(entered: entered, releasedBy: finishSetup)
                try Task.checkCancellation()
                return ["late-library-row"]
            }
        }
        await fulfillment(of: [entered], timeout: 2)
        sync.cancel()
        finishSetup.signal()
        do {
            _ = try await sync.value
            XCTFail("A timed-out sync must not publish the late response")
        } catch is CancellationError { } catch { XCTFail("Unexpected error: \(error)") }
        let result = await AppleMusicMediaLibraryGate.run { 42 }
        XCTAssertEqual(result, 42)
    }
}

final class AppleMusicLibrarySyncHistoryTests: XCTestCase {
    private func defaults() throws -> UserDefaults {
        let suite = "AppleMusicLibrarySyncHistoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testFirstSyncHasNoPreviousTimeAndSurvivesReload() throws {
        let defaults = try defaults()
        var history = AppleMusicLibrarySyncHistory.load(from: defaults)
        XCTAssertNil(history.completedAt)
        XCTAssertNil(history.previousCompletedAt)
        let first = Date(timeIntervalSince1970: 1_793_927_280)
        history.recordCompletion(songCount: 426, at: first, defaults: defaults)
        let restored = AppleMusicLibrarySyncHistory.load(from: defaults)
        XCTAssertEqual(restored.completedAt, first)
        XCTAssertEqual(restored.songCount, 426)
        XCTAssertNil(restored.previousCompletedAt)
    }

    func testResyncKeepsTheImmediatelyPreviousCompletionAcrossRestarts() throws {
        let defaults = try defaults()
        let first = Date(timeIntervalSince1970: 1_793_927_280)
        let second = first.addingTimeInterval(86_400)
        let third = second.addingTimeInterval(86_400)
        var history = AppleMusicLibrarySyncHistory.load(from: defaults)
        history.recordCompletion(songCount: 426, at: first, defaults: defaults)
        history = AppleMusicLibrarySyncHistory.load(from: defaults)
        history.recordCompletion(songCount: 427, at: second, defaults: defaults)
        XCTAssertEqual(history.previousCompletedAt, first)
        XCTAssertEqual(AppleMusicLibrarySyncHistory.load(from: defaults), history)
        history = AppleMusicLibrarySyncHistory.load(from: defaults)
        history.recordCompletion(songCount: 0, at: third, defaults: defaults)
        XCTAssertEqual(history.completedAt, third)
        XCTAssertEqual(history.previousCompletedAt, second)
        XCTAssertEqual(history.songCount, 0)
        XCTAssertEqual(AppleMusicLibrarySyncHistory.load(from: defaults), history)
    }

    func testRemovingTheSourceClearsItsPersistedHistory() throws {
        let defaults = try defaults()
        var history = AppleMusicLibrarySyncHistory()
        history.recordCompletion(songCount: 426, at: Date(), defaults: defaults)
        history.clear(defaults: defaults)
        XCTAssertEqual(history, AppleMusicLibrarySyncHistory())
        XCTAssertEqual(AppleMusicLibrarySyncHistory.load(from: defaults), history)
        history.recordCompletion(songCount: 12, at: Date(), defaults: defaults)
        XCTAssertNil(history.previousCompletedAt)
    }
}

final class AppleMusicPlaylistPaginationTests: XCTestCase, @unchecked Sendable {
    private let link = "https://music.apple.com/us/playlist/fixture/pl.fixture"
    func testInitialAndLaterSDKCancellationStayCancellation() async {
        for later in [false, true] {
            for cancellation in [CancellationError() as any Error, URLError(.cancelled)] {
                let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                    if !later { throw cancellation }
                    return .init(name: "Fixture", tracks: [Self.track(1)], next: { throw cancellation })
                })
                do { _ = try await fetcher.fetch(sharedText: link); XCTFail("Cancelled imports must not produce a playlist") }
                catch is CancellationError { }
                catch { XCTFail("Lost SDK cancellation: \(error)") }
            }
        }
    }
    func testLaterPageFailureKeepsReadPagesAsIncomplete() async throws {
        for failure in [URLError(.notConnectedToInternet) as any Error, ExternalPlaylistFetcher.FetchError.appleMusicNotAuthorized] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                .init(name: "Fixture", tracks: [Self.track(1)], next: {
                    .init(name: "Fixture", tracks: [Self.track(2)], next: { throw failure })
                })
            })
            let result = try await fetcher.fetch(sharedText: link)
            XCTAssertEqual(result.tracks.map(\.externalID), ["1", "2"])
            XCTAssertEqual(result.partialReason, .incomplete, "A missing page must never read as a complete playlist")
        }
    }
    func testAdvertisedContinuationWithoutAPageIsNotComplete() async throws {
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
            .init(name: "Fixture", tracks: [Self.track(1)], next: { nil })
        })
        let result = try await fetcher.fetch(sharedText: link)
        XCTAssertEqual(result.tracks.map(\.externalID), ["1"])
        XCTAssertEqual(result.partialReason, .incomplete)
    }
    func testSuccessfulPagesKeepOrderAndStopAtEnd() async throws {
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { id in
            XCTAssertEqual(id, "pl.fixture")
            return .init(name: "Fixture", tracks: [Self.track(1)], next: {
                .init(name: "Fixture", tracks: [Self.track(2), Self.track(3)])
            })
        })
        let result = try await fetcher.fetch(sharedText: link)
        XCTAssertEqual(result.name, "Fixture")
        XCTAssertEqual(result.tracks.map(\.externalID), ["1", "2", "3"])
        XCTAssertFalse(result.isPartial)
    }
    func testTrackCapDoesNotFetchAnUnneededPage() async throws {
        for extra in [0, 1] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
                .init(name: "Fixture", tracks: (0..<(ExternalPlaylistFetcher.maximumTracks + extra)).map(Self.track), next: {
                    XCTFail("Cap already reached; must not request another SDK page")
                    return nil
                })
            })
            let result = try await fetcher.fetch(sharedText: link)
            XCTAssertEqual(result.tracks.count, ExternalPlaylistFetcher.maximumTracks)
            XCTAssertEqual(result.tracks.last?.externalID, "9999")
        }
    }
    func testActualTaskCancellationDuringContinuationDoesNotReturnPartialResult() async throws {
        let started = expectation(description: "SDK continuation started")
        let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in
            .init(name: "Fixture", tracks: [Self.track(1)], next: {
                started.fulfill()
                try await Task.sleep(for: .seconds(60))
                return .init(name: "Fixture", tracks: [Self.track(2)])
            })
        })
        let link = link
        let task = Task { try await fetcher.fetch(sharedText: link) }
        await fulfillment(of: [started], timeout: 5)
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled import returned a playlist") }
        catch is CancellationError { }
    }
    func testSDKAuthorizationAndMissingPlaylistErrorsStaySpecific() async {
        for error in [ExternalPlaylistFetcher.FetchError.appleMusicNotAuthorized, .notFoundOrPrivate] {
            let fetcher = ExternalPlaylistFetcher(appleMusicPage: { _ in throw error })
            do { _ = try await fetcher.fetch(sharedText: link); XCTFail("Expected SDK precondition failure") }
            catch let actual as ExternalPlaylistFetcher.FetchError {
                switch (error, actual) {
                case (.appleMusicNotAuthorized, .appleMusicNotAuthorized), (.notFoundOrPrivate, .notFoundOrPrivate): break
                default: XCTFail("Lost specific SDK error")
                }
            } catch { XCTFail("Unexpected error: \(error)") }
        }
    }
    private static func track(_ index: Int) -> ExternalPlaylistTrack {
        .init(title: "Track \(index)", artists: ["Fixture"], externalID: String(index))
    }
}
