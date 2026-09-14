import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ScrapeOptionsTaskTests: XCTestCase {
    func testLyricsCacheReadsLocalBasenamesWithoutFollowingRemoteReferences() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsReferences-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MetadataAssetStore(storageDirectory: directory)
        let lines = [LyricLine(timestamp: 0, text: "Cached lyrics")]
        let fileName = await store.storeLyrics(lines, for: "cached-song")
        let cached = await store.lyrics(named: fileName)
        XCTAssertEqual(cached, lines)

        let nested = store.lyricsDirectoryURL.appendingPathComponent("remote", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try JSONEncoder().encode(lines).write(to: nested.appendingPathComponent("song.json"))
        for reference in ["remote/song.json", "/music/song.lrc", "https://nas.invalid/song.json",
                          "remote\\song.json", "song.lrc"] {
            let result = await store.lyrics(named: reference)
            XCTAssertNil(result)
        }
    }

    @MainActor
    private final class SuspendedRequest {
        let started = XCTestExpectation(description: "Request started")
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                started.fulfill()
            }
        }

        func complete() {
            continuation?.resume()
            continuation = nil
        }
    }

    func testCancelBeforeStartingDoesNotApplyChanges() async {
        let session = ScrapeOptionsTask()
        var applied = false
        let task = session.start { applied = true }

        session.cancel()
        await task.value

        XCTAssertFalse(applied)
        XCTAssertFalse(session.isRunning)
    }

    func testCancelReleasesBusyStateWithoutWaitingForNetwork() async {
        let session = ScrapeOptionsTask()
        let request = SuspendedRequest()
        var observedCancellation = false
        let task = session.start {
            await request.wait()
            observedCancellation = Task.isCancelled
        }
        await fulfillment(of: [request.started], timeout: 2)

        session.cancel()

        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(observedCancellation)
        request.complete()
        await task.value
        XCTAssertTrue(observedCancellation)
    }

    func testCancelledTaskHandleAlsoReleasesBusyState() async {
        let session = ScrapeOptionsTask()
        let task = session.start { XCTFail("Cancelled work must not start") }

        task.cancel()
        await task.value

        XCTAssertFalse(session.isRunning)
    }

    func testLateCompletionDoesNotClearReplacementBusyState() async {
        let session = ScrapeOptionsTask()
        let oldRequest = SuspendedRequest()
        let newRequest = SuspendedRequest()
        let oldTask = session.start { await oldRequest.wait() }
        await fulfillment(of: [oldRequest.started], timeout: 2)

        let newTask = session.start { await newRequest.wait() }
        await fulfillment(of: [newRequest.started], timeout: 2)
        oldRequest.complete()
        await oldTask.value

        XCTAssertTrue(oldTask.isCancelled)
        XCTAssertTrue(session.isRunning)
        newRequest.complete()
        await newTask.value
        XCTAssertFalse(session.isRunning)
    }

    func testClosingAfterSuccessfulApplyDoesNotCancelCommittedWriteback() async {
        let session = ScrapeOptionsTask()
        let writeback = SuspendedRequest()
        var writebackWasCancelled = true
        let task = session.start {
            session.finish()
            await writeback.wait()
            writebackWasCancelled = Task.isCancelled
        }
        await fulfillment(of: [writeback.started], timeout: 2)

        session.cancel()
        writeback.complete()
        await task.value

        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(writebackWasCancelled)
    }

    func testCancelledLyricsSavePreservesExistingLyricsAndAllowsRetry() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScrapeCancellationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary(storageDirectory: directory)
        let sourceManager = SourceManager(sourcesProvider: { [] })
        let songID = UUID().uuidString
        let oldLines = [LyricLine(timestamp: 0, text: "Original lyrics")]
        let newLines = [LyricLine(timestamp: 0, text: "Replacement lyrics")]
        var song = Song(
            id: songID, title: "Song", fileFormat: .mp3,
            filePath: "/test/song.mp3", sourceID: "scrape-test"
        )
        song.lyricsText = "Original lyrics"
        song.lyricsFileName = MetadataAssetStore.shared.expectedLyricsFileName(for: songID)
        let seeded = await MetadataAssetStore.shared.cacheLyrics(oldLines, forSongID: songID)
        XCTAssertTrue(seeded)
        library.addSongs([song], affectedSourceIDs: [song.sourceID])
        let storedSong = try XCTUnwrap(library.song(id: songID))
        let fingerprint = LyricsDocumentFingerprint(lines: oldLines)
        let save = Task { @MainActor in
            await LyricsWriteback.save(
                text: LyricsContentParser.serialize(newLines), for: storedSong,
                mode: .localOnly(reason: nil), allowRemoval: false,
                structuredLines: newLines, cacheSnapshot: fingerprint,
                sourceManager: sourceManager, library: library
            )
        }
        save.cancel()
        let cancelled = await save.value

        XCTAssertFalse(cancelled.succeeded)
        XCTAssertEqual(library.song(id: songID)?.lyricsText, "Original lyrics")
        let unchanged = await MetadataAssetStore.shared.cachedLyrics(forSongID: songID)
        XCTAssertEqual(unchanged?.map(\.text), ["Original lyrics"])

        let retried = await LyricsWriteback.save(
            text: LyricsContentParser.serialize(newLines), for: storedSong,
            mode: .localOnly(reason: nil), allowRemoval: false,
            structuredLines: newLines, cacheSnapshot: fingerprint,
            sourceManager: sourceManager, library: library
        )
        XCTAssertTrue(retried.succeeded, retried.errorMessage ?? "")
        XCTAssertEqual(library.song(id: songID)?.lyricsText, "Replacement lyrics")
        _ = await MetadataAssetStore.shared.invalidateLyricsCacheIfUnchanged(
            forSongID: songID, expectedFingerprint: retried.cacheSnapshot
        )
    }
}
