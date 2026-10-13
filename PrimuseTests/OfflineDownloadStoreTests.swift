import XCTest
import PrimuseKit
@testable import Primuse

/// 离线下载在缓存目录之外另存一个入口(硬链接), 不计入缓存上限。
final class OfflineDownloadStoreTests: XCTestCase {
    private struct Fixture {
        let relativePath: String
        let cacheURL: URL
        let mirrorURL: URL
        let markerURL: URL
        let sourceDirectories: [URL]
    }

    private func makeFixture(byteCount: Int = 64 * 1_024) throws -> Fixture {
        let sourceID = "offline-store-\(UUID().uuidString)"
        let relativePath = "\(sourceID)/track.flac"
        let cacheRoot = FileManager.default.primuseDirectoryURL(for: .cachesDirectory)
            .appendingPathComponent("primuse_audio_cache", isDirectory: true)
        let offlineRoot = FileManager.default.primuseDirectoryURL(for: .applicationSupportDirectory)
            .appendingPathComponent("primuse_offline_audio", isDirectory: true)
        let cacheURL = cacheRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: cacheURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 7, count: byteCount).write(to: cacheURL)
        return Fixture(
            relativePath: relativePath,
            cacheURL: cacheURL,
            mirrorURL: offlineRoot.appendingPathComponent(relativePath),
            markerURL: cacheRoot.appendingPathComponent(".offline_mirror_intact"),
            sourceDirectories: [
                cacheRoot.appendingPathComponent(sourceID, isDirectory: true),
                offlineRoot.appendingPathComponent(sourceID, isDirectory: true),
            ]
        )
    }

    private func cleanUp(_ fixture: Fixture) async {
        await AudioCacheManager.shared.removeEntry(path: fixture.relativePath)
        for directory in fixture.sourceDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private func inode(_ url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }

    func testPinnedFileGetsAnOfflineEntryForTheSameBytes() async throws {
        let fixture = try makeFixture()
        await AudioCacheManager.shared.refreshPathFamily(path: fixture.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mirrorURL.path))

        await AudioCacheManager.shared.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        XCTAssertEqual(inode(fixture.mirrorURL), inode(fixture.cacheURL))

        await AudioCacheManager.shared.unpin(path: fixture.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mirrorURL.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: fixture.cacheURL.path),
            "An unpinned download stays as ordinary cache"
        )
        await cleanUp(fixture)
    }

    func testRemovingTheDownloadAlsoRemovesTheOfflineEntry() async throws {
        let fixture = try makeFixture()
        await AudioCacheManager.shared.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mirrorURL.path))

        await AudioCacheManager.shared.removeEntry(path: fixture.relativePath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mirrorURL.path))
        await cleanUp(fixture)
    }

    func testOfflineEntryComesBackAfterTheSystemClearsTheCacheDirectory() async throws {
        let fixture = try makeFixture()
        await AudioCacheManager.shared.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        let pinnedInode = inode(fixture.cacheURL)

        // 系统清缓存目录: 文件和「缓存目录完好」标记一起没了。
        try FileManager.default.removeItem(at: fixture.cacheURL)
        try? FileManager.default.removeItem(at: fixture.markerURL)
        await AudioCacheManager.shared.resyncOfflineStoreForTesting()

        XCTAssertEqual(inode(fixture.cacheURL), pinnedInode)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))
        let isPinned = await AudioCacheManager.shared.isPinned(path: fixture.relativePath)
        XCTAssertTrue(isPinned)
        await cleanUp(fixture)
    }

    func testDeletingAPinnedFileOnPurposeDoesNotResurrectIt() async throws {
        let fixture = try makeFixture()
        await AudioCacheManager.shared.pin(path: fixture.relativePath, byteCount: 64 * 1_024)
        await AudioCacheManager.shared.resyncOfflineStoreForTesting()
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.markerURL.path))

        try FileManager.default.removeItem(at: fixture.cacheURL)
        await AudioCacheManager.shared.resyncOfflineStoreForTesting()

        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mirrorURL.path))
        await cleanUp(fixture)
    }

    func testPinnedBytesDoNotCountTowardTheCacheLimit() async throws {
        let byteCount = 256 * 1_024
        let fixture = try makeFixture(byteCount: byteCount)
        let before = await AudioCacheManager.shared.totalCacheSize()
        await AudioCacheManager.shared.refreshPathFamily(path: fixture.relativePath)
        let cached = await AudioCacheManager.shared.totalCacheSize()
        XCTAssertGreaterThanOrEqual(cached - before, Int64(byteCount))

        await AudioCacheManager.shared.pin(path: fixture.relativePath, byteCount: Int64(byteCount))
        let pinned = await AudioCacheManager.shared.totalCacheSize()
        XCTAssertEqual(pinned, before)
        await cleanUp(fixture)
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

/// 一次性用途的整首下载用完即删。
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
}
