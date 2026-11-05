import XCTest
import PrimuseKit
@testable import Primuse

/// All filesystem regressions use an isolated container, never the app's downloads.
final class OfflineDownloadStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let relativePath: String
        let cacheURL: URL
        let manager: AudioCacheManager
    }

    private func makeFixture(byteCount: Int = 64 * 1_024) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OfflineStoreTests-\(UUID().uuidString)")
        let cache = root.appendingPathComponent("Caches")
        let path = "source/track.flac"
        let file = cache.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: byteCount).write(to: file)
        let manager = AudioCacheManager(cacheDirectory: cache,
            offlineDirectory: root.appendingPathComponent("Private"),
            downloadsDirectory: root.appendingPathComponent("Downloads"))
        addTeardownBlock {
            await manager.finishOfflineStoreTesting()
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(root: root, relativePath: path, cacheURL: file, manager: manager)
    }

    private func inode(_ url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func testPinnedFileGetsAnIndependentDownloadWithoutDuplicatingBytes() async throws {
        let fixture = try makeFixture()
        let installed = await fixture.manager.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        XCTAssertTrue(installed)
        let download = try XCTUnwrap(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        XCTAssertEqual(inode(download), inode(fixture.cacheURL))
        await fixture.manager.unpin(path: fixture.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
    }

    func testRemovingDownloadAlsoRemovesFileInDownloads() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        let download = try XCTUnwrap(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        await fixture.manager.removeEntry(path: fixture.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: download.path))
    }

    func testRemovedDownloadIsNotRecreatedByALateLeaseRelease() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536)
        let activeLease = await fixture.manager.acquirePathFamilyLease(path: fixture.relativePath)
        let lease = try XCTUnwrap(activeLease)
        try fixture.manager.downloadStore.remove(fixture.relativePath, recordRemoval: true)
        try FileManager.default.removeItem(at: fixture.cacheURL)
        await fixture.manager.releasePathFamilyLease(lease)
        XCTAssertNil(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        await fixture.manager.removeEntry(path: fixture.relativePath)
        XCTAssertTrue(fixture.manager.downloadStore.wasExternallyRemoved(fixture.relativePath))
    }

    func testClearingOneCacheFilePreservesDownloadAndListWithoutAMarker() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        let savedInode = inode(fixture.cacheURL)
        try FileManager.default.removeItem(at: fixture.cacheURL)
        let entries = await fixture.manager.offlineDownloadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertGreaterThan(entries.first?.byteCount ?? 0, 0)
        await fixture.manager.resyncOfflineStoreForTesting()
        XCTAssertEqual(inode(fixture.cacheURL), savedInode)
        let snapshot = await fixture.manager.snapshot(path: fixture.relativePath, fileExists: false, byteCount: nil)
        XCTAssertTrue(snapshot.isDownloaded)
    }

    func testDeletingFromFilesRemovesPinAndStaleCacheAlias() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        let download = try XCTUnwrap(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        try FileManager.default.removeItem(at: download)
        await fixture.manager.resyncOfflineStoreForTesting()
        let entries = await fixture.manager.offlineDownloadEntries()
        XCTAssertTrue(entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertTrue(fixture.manager.downloadStore.wasExternallyRemoved(fixture.relativePath))
    }

    func testLegacyOfflineFileMigratesWhenCacheFileWasAlreadyDeleted() async throws {
        let fixture = try makeFixture()
        let legacy = fixture.root.appendingPathComponent("Private/\(fixture.relativePath)")
        try FileManager.default.createDirectory(at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: fixture.cacheURL, to: legacy)
        let manifest: [String: Any] = [fixture.relativePath: ["isManuallyPinned": true, "playlistIDs": [], "byteCount": 65536]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: fixture.root.appendingPathComponent("Private/.offline_manifest.json"))
        await fixture.manager.resyncOfflineStoreForTesting()
        XCTAssertNotNil(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        let entries = await fixture.manager.offlineDownloadEntries()
        XCTAssertEqual(entries.count, 1)
    }

    func testPinnedBytesDoNotCountTowardCacheLimit() async throws {
        let fixture = try makeFixture(byteCount: 256 * 1_024)
        let cached = await fixture.manager.totalCacheSize()
        XCTAssertGreaterThanOrEqual(cached, 256 * 1_024)
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 256 * 1_024)
        let pinned = await fixture.manager.totalCacheSize()
        XCTAssertEqual(pinned, 0)
    }

    func testPlaylistDownloadSurvivesClearingTheEntireCache() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536, forPlaylistIDs: ["playlist"])
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("Caches"))
        await fixture.manager.clearUnpinnedAccessEntries()
        let entries = await fixture.manager.offlineDownloadEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.playlistIDs, ["playlist"])
        XCTAssertFalse(entries.first?.isManuallyPinned ?? true)
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), Data(repeating: 7, count: 65_536))
    }

    func testDownloadSurvivesCacheCleanerEvenIfPinProtectionIsMissing() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536, forPlaylistIDs: ["playlist"])
        let cache = fixture.root.appendingPathComponent("Caches")
        let result = await SourceManager.removeUnpinnedAudioCacheFiles(
            dirs: [cache], basePath: cache, removableDirPaths: [],
            pinnedRelativePaths: [], protectedAbsolutePaths: []
        )
        XCTAssertGreaterThan(result.freedBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        await fixture.manager.clearUnpinnedAccessEntries()
        let entries = await fixture.manager.offlineDownloadEntries()
        XCTAssertEqual(entries.first?.playlistIDs, ["playlist"])
        XCTAssertEqual(try Data(contentsOf: fixture.cacheURL), Data(repeating: 7, count: 65_536))
    }

    func testExternalDeletionBlocksAutomaticDownloadButAllowsPlaybackCacheAndManualDownload() async throws {
        let fixture = try makeFixture()
        await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536, forPlaylistIDs: ["playlist"])
        let download = try XCTUnwrap(fixture.manager.downloadStore.fileURL(for: fixture.relativePath, kind: .original))
        try FileManager.default.removeItem(at: download)
        try Data(repeating: 9, count: 65_536).write(to: fixture.cacheURL, options: .atomic)
        await fixture.manager.markDownloaded(path: fixture.relativePath, byteCount: 65_536, pinned: false)
        let automatic = await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536, forPlaylistIDs: ["playlist"])
        XCTAssertFalse(automatic)
        let cached = await fixture.manager.snapshot(path: fixture.relativePath, fileExists: true, byteCount: 65_536)
        XCTAssertEqual(cached.state, .cached)
        let manual = await fixture.manager.pin(path: fixture.relativePath, byteCount: 65_536)
        XCTAssertTrue(manual)
        XCTAssertFalse(fixture.manager.downloadStore.wasExternallyRemoved(fixture.relativePath))
    }

    func testPlaybackCacheIsAvailableOfflineButNotInDownloadedFilter() {
        let cached = OfflineAudioCacheSnapshot(state: .cached, progress: nil, byteCount: 10, errorMessage: nil)
        XCTAssertTrue(cached.isAvailableLocally)
        XCTAssertFalse(cached.isDownloaded)
        let downloaded = OfflineAudioCacheSnapshot(state: .pinned, progress: nil, byteCount: 10, errorMessage: nil)
        XCTAssertTrue(downloaded.isDownloaded)
    }

    func testCacheClearRecognizesPinnedFilesThroughAnAliasedRoot() throws {
        let fixture = try makeFixture()
        let alias = fixture.root.appendingPathComponent("CachesAlias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root.appendingPathComponent("Caches"))
        XCTAssertTrue(SourceManager.audioCacheClearShouldSkip(
            fileURL: fixture.cacheURL, basePath: alias,
            pinnedRelativePaths: [fixture.relativePath], protectedAbsolutePaths: []
        ))
        XCTAssertFalse(SourceManager.audioCacheClearShouldSkip(
            fileURL: fixture.cacheURL, basePath: alias,
            pinnedRelativePaths: [], protectedAbsolutePaths: []
        ))
    }

    func testOfflineListCountsASharedFileOnceAndShowsNewestFirst() {
        let older = Song(id: "older", title: "Older", fileFormat: .flac,
                         filePath: "/music/older.flac", sourceID: "source", fileSize: 10)
        let cueFirst = Song(id: "cue-1", title: "Track 1", fileFormat: .flac,
                            filePath: "/music/album.flac", sourceID: "source", fileSize: 100)
        let cueSecond = Song(id: "cue-2", title: "Track 2", fileFormat: .flac,
                             filePath: "/music/album.flac", sourceID: "source", fileSize: 100)
        let notDownloaded = Song(id: "other", title: "Other", fileFormat: .flac,
                                 filePath: "/music/other.flac", sourceID: "source", fileSize: 10)
        func path(_ song: Song) -> String {
            "source/" + CacheFileNamePolicy.make(path: song.filePath, preferredExtension: "flac")
        }
        let entries = [
            AudioCacheManager.OfflineDownloadEntry(
                path: path(older),
                playlistIDs: [],
                isManuallyPinned: true,
                byteCount: 10,
                downloadedAt: Date(timeIntervalSince1970: 100)
            ),
            AudioCacheManager.OfflineDownloadEntry(
                path: path(cueFirst),
                playlistIDs: ["playlist"],
                isManuallyPinned: false,
                byteCount: 500,
                downloadedAt: Date(timeIntervalSince1970: 200)
            ),
        ]
        let items = SourceManager.offlineDownloadItems(
            entries: entries,
            songs: [older, cueFirst, cueSecond, notDownloaded]
        )
        XCTAssertEqual(items.map(\.id), ["cue-1", "cue-2", "older"])
        XCTAssertEqual(items.reduce(0) { $0 + $1.byteCount }, 510)
        XCTAssertEqual(items.first?.playlistIDs, ["playlist"])
    }

    func testRemovalTurnsOffOnlyPlaylistsThatStillKeepTheSongs() {
        let song = Song(id: "song", title: "Song", fileFormat: .flac,
                        filePath: "/music/song.flac", sourceID: "source", fileSize: 10)
        let item = SourceManager.OfflineDownloadItem(
            song: song,
            byteCount: 10,
            playlistIDs: ["enabled", "already-off"],
            downloadedAt: nil
        )
        let request = OfflineDownloadRemovalRequest.make(
            for: [item],
            enabledPlaylistIDs: ["enabled", "unrelated"]
        )
        XCTAssertEqual(request.playlistIDs, ["enabled"])
        XCTAssertEqual(request.byteCount, 10)
        XCTAssertEqual(request.songs.map(\.id), ["song"])
    }
}

/// 一次性整首下载用完即删, 以及存储管理里「音乐源文件缓存」的统计与清除。
/// 用真实的 Caches / tmp 路径: 设备上 tmp 是 /private/var 开头, Caches 是 /var 开头,
/// 两边要统一成同一种写法才比得上, 这一点只有 Apple 平台上测得到。
final class SourceFileCacheStorageTests: XCTestCase {
    private var createdDirectories: [URL] = []

    override func tearDown() {
        for directory in createdDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        createdDirectories = []
        super.tearDown()
    }

    private func makeFile(in base: URL, _ components: [String], bytes: Int = 4_096) throws -> URL {
        var directory = base
        for component in components.dropLast() {
            directory.appendPathComponent(component, isDirectory: true)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(components.last!)
        try Data(repeating: 0x5A, count: bytes).write(to: file)
        return file
    }

    private func sourceRoot(_ name: String, temporary: Bool, sourceID: String) -> URL {
        let base = temporary
            ? FileManager.default.temporaryDirectory
            : FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
        let root = base.appendingPathComponent(name).appendingPathComponent(sourceID)
        createdDirectories.append(root)
        return root
    }

    func testFreshConnectorDownloadsAreDiscardedInCachesAndTemporaryDirectories() throws {
        let sourceID = "test-one-off-\(UUID().uuidString)"
        let startedAt = Date()
        let s3 = try makeFile(
            in: sourceRoot("primuse_s3_cache", temporary: false, sourceID: sourceID),
            ["ns", "song.mp3"]
        )
        let webDAV = try makeFile(
            in: sourceRoot("primuse_webdav_cache", temporary: true, sourceID: sourceID),
            ["ns", "song.mp3"]
        )

        for file in [s3, webDAV] {
            XCTAssertTrue(
                SourceManager.isOneOffSourceDownload(file, sourceID: sourceID, downloadedSince: startedAt),
                file.path
            )
            SourceManager.discardOneOffSourceDownload(file, sourceID: sourceID, downloadedSince: startedAt)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), file.path)
        }
    }

    func testCopiesThatExistedBeforeTheCallAreKept() throws {
        let sourceID = "test-one-off-\(UUID().uuidString)"
        let file = try makeFile(
            in: sourceRoot("primuse_webdav_cache", temporary: true, sourceID: sourceID),
            ["ns", "song.wma"]
        )
        Thread.sleep(forTimeInterval: 0.02)
        let startedAt = Date()

        SourceManager.discardOneOffSourceDownload(file, sourceID: sourceID, downloadedSince: startedAt)

        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testAudioCacheAndFilesOutsideConnectorCachesAreNeverDiscarded() throws {
        let sourceID = "test-one-off-\(UUID().uuidString)"
        let startedAt = Date()
        let audioCache = try makeFile(
            in: sourceRoot("primuse_audio_cache", temporary: false, sourceID: sourceID),
            ["song.flac"]
        )
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("test-one-off-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(documents)
        let localOriginal = try makeFile(in: documents, ["song.flac"])
        let otherSource = try makeFile(
            in: sourceRoot("primuse_s3_cache", temporary: false, sourceID: sourceID + "-other"),
            ["ns", "song.mp3"]
        )

        for file in [audioCache, localOriginal, otherSource] {
            SourceManager.discardOneOffSourceDownload(file, sourceID: sourceID, downloadedSince: startedAt)
            XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        }
    }

    func testRemovingFilesKeepsDirectoriesAndProtectedFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-source-files-\(UUID().uuidString)", isDirectory: true)
        createdDirectories.append(root)
        let plain = try makeFile(in: root, ["ns", "a.mp3"])
        let hidden = try makeFile(in: root, ["ns", ".b.part-1"])
        let kept = try makeFile(in: root, ["ns", "c.mp3"])

        XCTAssertGreaterThanOrEqual(SourceManager.allocatedFileBytes(under: root), 3 * 4_096)

        let result = SourceManager.removeFiles(
            under: root,
            protectedPaths: [kept.standardizedFileURL.path]
        )

        XCTAssertEqual(result.failedCount, 0)
        XCTAssertGreaterThanOrEqual(result.freedBytes, 2 * 4_096)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plain.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: hidden.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("ns").path,
            isDirectory: &isDirectory
        ))
        XCTAssertTrue(isDirectory.boolValue)
    }
}
