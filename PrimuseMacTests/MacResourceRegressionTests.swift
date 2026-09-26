import AppKit
import AVFoundation
import XCTest
import PrimuseKit
@testable import Primuse

@MainActor
final class MacResourceRegressionTests: XCTestCase {
    func testCacheCompletionDoesNotEnumerateLibraryAndUpdatesAllRowsSharingAFile() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Cache fixture", type: .navidrome)
        let first = Song(id: UUID().uuidString, title: "First", fileFormat: .flac,
                         filePath: "/fixture.flac", sourceID: source.id, fileSize: 128)
        var second = first
        second.id = UUID().uuidString
        var libraryReads = 0
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: {
            libraryReads += 1
            return [first, second]
        })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: first, forceRedownload: false) }
        defer { manager.deleteLocalCaches(for: [first, second]) }
        await manager.prepareOfflineAudioSnapshots(for: [first, second])
        let firstEntry = manager.offlineAudioSnapshotEntry(for: first)
        let secondEntry = manager.offlineAudioSnapshotEntry(for: second)
        let url = manager.cacheURL(for: first)
        let path = source.id + "/" + url.lastPathComponent
        let readsBeforeCompletion = libraryReads
        try Data(repeating: 7, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: path)
        try await waitUntilAsync { firstEntry.snapshot.isDownloaded && secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion, "A cache notification must not scan the song library")
        await AudioCacheManager.shared.removeEntry(path: path)
        try await waitUntilAsync { !firstEntry.snapshot.isDownloaded && !secondEntry.snapshot.isDownloaded }
        XCTAssertEqual(libraryReads, readsBeforeCompletion)
    }

    func testCacheNotificationsFollowSongRenames() async throws {
        let source = MusicSource(id: UUID().uuidString, name: "Rename fixture", type: .navidrome)
        let previous = Song(id: UUID().uuidString, title: "Track", fileFormat: .flac,
                            filePath: "/before.flac", sourceID: source.id, fileSize: 128)
        var current = previous
        let manager = SourceManager(sourcesProvider: { [source] }, songsProvider: { [current] })
        try await waitUntilAsync { await manager.prepareAutomaticOfflineDownload(song: previous, forceRedownload: false) }
        await manager.ensureOfflineAudioSnapshot(for: previous)
        let entry = manager.offlineAudioSnapshotEntry(for: previous)
        _ = manager.cacheURL(for: previous)
        current.filePath = "/after.flac"
        defer { manager.deleteLocalCaches(for: [previous, current]) }
        NotificationCenter.default.post(name: .primuseSongLocationChanged, object: nil,
                                        userInfo: ["previousSongs": [previous], "songs": [current]])
        try await Task.sleep(for: .milliseconds(100))
        let url = manager.audioCacheTargetURL(for: current)
        try Data(repeating: 9, count: 128).write(to: url)
        await AudioCacheManager.shared.recordAccess(path: source.id + "/" + url.lastPathComponent)
        try await waitUntilAsync { entry.snapshot.isDownloaded }
    }

    func testUnrelatedCacheNotificationDoesNotReadLibrary() async throws {
        var reads = 0
        let manager = SourceManager(sourcesProvider: { [] }, songsProvider: { reads += 1; return [] })
        // Let initial source validation finish before isolating the notification.
        try await Task.sleep(for: .milliseconds(150))
        let before = reads
        NotificationCenter.default.post(name: .primuseAudioCacheFilesDidChange, object: nil,
                                        userInfo: ["paths": [UUID().uuidString + "/unknown.flac"]])
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(reads, before)
        withExtendedLifetime(manager) {}
    }

    func testUnavailableBookmarkFailsClosedWithoutFallingBackToBasePath() async throws {
        let sourceID = UUID().uuidString
        let key = "primuse.localBookmark." + sourceID
        UserDefaults.standard.set(Data([0, 1, 2]), forKey: key)
        defer { LocalBookmarkStore.remove(sourceID: sourceID) }
        let connector = LocalFileSource(sourceID: sourceID, basePath: FileManager.default.temporaryDirectory)
        do {
            _ = try await connector.localURL(for: "/")
            XCTFail("A corrupt bookmark cannot grant access through the fallback directory")
        } catch SourceError.credentialUnavailable { }
    }

    func testLocalConnectorLazilyResolvesBeforeListingWithoutAnExplicitConnect() async throws {
        let sourceID = UUID().uuidString
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(sourceID)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: root.appendingPathComponent("fixture.txt"))
        defer { try? FileManager.default.removeItem(at: root); LocalBookmarkStore.remove(sourceID: sourceID) }
        try LocalBookmarkStore.save(sourceID: sourceID, url: root)
        let connector = LocalFileSource(sourceID: sourceID, basePath: root.appendingPathComponent("incorrect-fallback"))
        let files = try await connector.listFiles(at: "/")
        XCTAssertEqual(files.map(\.name), ["fixture.txt"])
    }

    func testKaraokeAudioUnitLoadsInsideApplicationSandbox() throws {
        let control = KaraokeRenderControl()
        let node = try XCTUnwrap(KaraokeVocalReducerUnit.makeNode(control: control))
        let unit = try XCTUnwrap(node.auAudioUnit as? KaraokeVocalReducerUnit)
        XCTAssertTrue(unit.control === control)
        try unit.allocateRenderResources()
        unit.deallocateRenderResources()
    }

    private func waitUntilAsync(_ predicate: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !(await predicate()) {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
