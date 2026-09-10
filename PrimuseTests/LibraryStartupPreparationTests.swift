import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// `onReady` 回调的顺序记录器。转义闭包不能捕获可变局部变量,
/// 所以用一个主线程隔离的引用类型收集执行顺序。
@MainActor
private final class ReadinessRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}

/// Stage 1 的启动准备/发布回归。覆盖:
/// - 离线准备 (`prepareStartup` + `init(preparedStartup:)`) 与同步装载的结果一致;
/// - `.preparing` 期间的突变排队与重放 (S2);
/// - `.preparing` 期间不落盘 (S1);
/// - `onReady` 的执行时机 (S3 的驱动机制);
/// - 被丢弃的准备不会改动磁盘 (G5)。
@MainActor
final class LibraryStartupPreparationTests: XCTestCase {

    // MARK: - Fixtures

    private static func makeStorageDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrimuseLibraryStartupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func makeSong(
        id: String,
        sourceID: String,
        title: String? = nil,
        filePath: String? = nil
    ) -> Song {
        Song(
            id: id,
            title: title ?? "Title \(id)",
            albumTitle: "Album \(sourceID)",
            artistName: "Artist \(sourceID)",
            duration: 180,
            fileFormat: .flac,
            filePath: filePath ?? "/Music/\(sourceID)/\(id).flac",
            sourceID: sourceID
        )
    }

    /// 写出一份完整的库: 两个源的歌曲、一个歌单、一条同步墓碑、一条设备本地排除。
    @discardableResult
    private static func populate(_ directory: URL) async throws -> [String] {
        let library = MusicLibrary(storageDirectory: directory)
        let sourceA = "source-a"
        let sourceB = "source-b"
        let a1 = makeSong(id: "a1", sourceID: sourceA)
        let a2 = makeSong(id: "a2", sourceID: sourceA)
        let b1 = makeSong(id: "b1", sourceID: sourceB)
        let b2 = makeSong(id: "b2", sourceID: sourceB)
        library.addSongs([a1, a2], affectedSourceIDs: [sourceA])
        library.addSongs([b1, b2], affectedSourceIDs: [sourceB])
        _ = library.createPlaylist(name: "Mixed", songIDs: [a1.id, b1.id])
        // 同步墓碑: 会随快照同步到其它设备。
        _ = library.deleteSong(a2)
        // 设备本地排除: 只留在本机账本里。
        _ = try library.removeSongsFromThisDevice([b2])
        guard case .success = await library.persistNowAndWait() else {
            throw XCTSkip("The isolated library did not finish persistence")
        }
        return library.songs.map(\.id)
    }

    private static func copyDirectory(_ source: URL) throws -> URL {
        let destination = try makeStorageDirectory()
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - Parity assertions

    private func assertParity(
        synchronous: MusicLibrary,
        prepared: MusicLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(
            synchronous.songs.map(\.id),
            prepared.songs.map(\.id),
            "songs differ",
            file: file,
            line: line
        )
        // `songIndexByID` 覆盖度: 每个 id 都必须能解析回同一行。
        for id in synchronous.songs.map(\.id) {
            XCTAssertEqual(
                prepared.song(id: id)?.id,
                id,
                "song(id:) failed to resolve \(id) on the prepared library",
                file: file,
                line: line
            )
            XCTAssertEqual(
                synchronous.song(id: id)?.id,
                id,
                "song(id:) failed to resolve \(id) on the synchronous library",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            synchronous.albums.count,
            prepared.albums.count,
            "album counts differ",
            file: file,
            line: line
        )
        XCTAssertEqual(
            synchronous.artists.count,
            prepared.artists.count,
            "artist counts differ",
            file: file,
            line: line
        )
        XCTAssertEqual(
            synchronous.visibleSongs.map(\.id),
            prepared.visibleSongs.map(\.id),
            "visibleSongs differ",
            file: file,
            line: line
        )
        XCTAssertEqual(
            synchronous.allPlaylists.map(\.id),
            prepared.allPlaylists.map(\.id),
            "playlists differ",
            file: file,
            line: line
        )
        // `playlistSongIDs` 是私有存储, 通过公开访问器比较其成员与顺序。
        for playlist in synchronous.allPlaylists {
            XCTAssertEqual(
                synchronous.songs(forPlaylist: playlist.id).map(\.id),
                prepared.songs(forPlaylist: playlist.id).map(\.id),
                "playlist \(playlist.id) membership differs",
                file: file,
                line: line
            )
        }
        XCTAssertEqual(
            synchronous.deletedSongIdentities,
            prepared.deletedSongIdentities,
            "deletedSongIdentities differ",
            file: file,
            line: line
        )
        XCTAssertEqual(
            synchronous.deviceLocalExcludedSongIdentities,
            prepared.deviceLocalExcludedSongIdentities,
            "deviceLocalExcludedSongIdentities differ",
            file: file,
            line: line
        )
        XCTAssertTrue(synchronous.isReady, "synchronous library is not ready", file: file, line: line)
        XCTAssertTrue(prepared.isReady, "published library is not ready", file: file, line: line)
    }

    private func openBothWays(
        _ fixture: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let synchronousDirectory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: synchronousDirectory) }
        let preparedDirectory = try Self.copyDirectory(fixture)
        defer { try? FileManager.default.removeItem(at: preparedDirectory) }

        let synchronous = MusicLibrary(storageDirectory: synchronousDirectory)
        let preparation = await MusicLibrary.prepareStartup(
            storageDirectory: preparedDirectory,
            sourceIdentityPrefixes: [:]
        )
        let published = MusicLibrary(preparedStartup: preparation)
        assertParity(synchronous: synchronous, prepared: published, file: file, line: line)
    }

    // MARK: - T1 parity

    func testPreparedStartupMatchesTheSynchronousLoadForAStartupCacheHit() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.appendingPathComponent("library-startup-cache.plist").path
            ),
            "the fixture should contain a startup cache"
        )
        try await openBothWays(fixture)
    }

    func testPreparedStartupMatchesTheSynchronousLoadWithoutAStartupCache() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)
        try? FileManager.default.removeItem(
            at: fixture.appendingPathComponent("library-startup-cache.plist")
        )
        try await openBothWays(fixture)
    }

    func testPreparedStartupMatchesTheSynchronousLoadForACorruptSnapshotWithBackup() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)

        let snapshotURL = fixture.appendingPathComponent("library-cache.json")
        let backupURL = fixture.appendingPathComponent("library-cache.backup.json")
        let valid = try Data(contentsOf: snapshotURL)
        try valid.write(to: backupURL, options: .atomic)
        try Data("{ not json".utf8).write(to: snapshotURL, options: .atomic)
        // 指纹不再匹配, 启动缓存会被拒绝, 装载落到 JSON/损坏分支。
        try await openBothWays(fixture)
    }

    // MARK: - T2 queued mutations

    func testMutationsBeforePublicationAreQueuedAndReplayedInOrder() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let seedLibrary = MusicLibrary(storageDirectory: fixture)
        let a1 = Self.makeSong(id: "a1", sourceID: "source-a")
        let b1 = Self.makeSong(id: "b1", sourceID: "source-b")
        seedLibrary.addSongs([a1], affectedSourceIDs: ["source-a"])
        seedLibrary.addSongs([b1], affectedSourceIDs: ["source-b"])
        guard case .success = await seedLibrary.persistNowAndWait() else {
            throw XCTSkip("The isolated library did not finish persistence")
        }

        let library = MusicLibrary.makePreparing(storageDirectory: fixture)
        XCTAssertEqual(library.readiness, .preparing)
        XCTAssertTrue(library.songs.isEmpty)

        let queued = Self.makeSong(id: "c1", sourceID: "source-c", title: "First")
        var replaced = queued
        replaced.title = "Second"
        library.addSongs([queued], affectedSourceIDs: ["source-c"])
        library.replaceSongs([replaced])
        _ = library.deleteSongs([a1])

        // 排队期间库不动。
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertEqual(library.readiness, .preparing)

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: fixture)
        library.publish(preparation)

        XCTAssertEqual(library.readiness, .ready)
        // 已发布的行在前, 排队突变按 FIFO 重放: 先 add 再 replace 再 delete。
        XCTAssertEqual(library.songs.map(\.id), ["b1", "c1"])
        XCTAssertEqual(library.song(id: "c1")?.title, "Second")
        XCTAssertNil(library.song(id: "a1"))
    }

    // MARK: - T3 no persistence before readiness

    func testNoPersistenceHappensBeforePublication() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let snapshotURL = directory.appendingPathComponent("library-cache.json")
        let startupCacheURL = directory.appendingPathComponent("library-startup-cache.plist")

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        library.persistNow()
        library.addSongs([Self.makeSong(id: "queued", sourceID: "source-a")])
        library.persistNow()

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshotURL.path),
            "library-cache.json must not be written while preparing"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: startupCacheURL.path),
            "library-startup-cache.plist must not be written while preparing"
        )

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: directory)
        library.publish(preparation)
        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The published library did not finish persistence")
            return
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: startupCacheURL.path))
        XCTAssertEqual(library.songs.map(\.id), ["queued"])
    }

    // MARK: - T4 readiness handlers

    /// 采用 `MusicLibrary.onReady` 顺序变体: 直接构造 `MetadataBackfillService`
    /// 需要真实的 SourceManager, 而且它的 init 会写真实的 Application Support
    /// 目录与 `primuse.backfill…` UserDefaults done-key, 在测试里不可隔离。
    /// 这里验证的是 Step C 依赖的那一个机制: 回调只在发布后运行一次。
    func testOnReadyHandlersRunOnceAfterPublicationAndImmediatelyAfterwards() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)

        let library = MusicLibrary.makePreparing(storageDirectory: fixture)
        let recorder = ReadinessRecorder()
        library.onReady { recorder.record("first") }
        library.onReady { recorder.record("second") }
        XCTAssertTrue(recorder.events.isEmpty, "handlers must not run while preparing")

        let waiter = Task { @MainActor in
            await library.whenReady()
            return library.isReady
        }

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: fixture)
        library.publish(preparation)

        XCTAssertEqual(recorder.events, ["first", "second"])
        let waiterSawReadyLibrary = await waiter.value
        XCTAssertTrue(waiterSawReadyLibrary)

        library.onReady { recorder.record("third") }
        XCTAssertEqual(recorder.events, ["first", "second", "third"])

        // 再次发布不会重放已经消费过的回调。
        let second = await MusicLibrary.prepareStartup(storageDirectory: fixture)
        library.publish(second)
        XCTAssertEqual(recorder.events, ["first", "second", "third"])
    }

    // MARK: - Early-return parity (C2)

    /// 快照文件不可读时, 历史版本的 `loadSnapshot` 直接返回, 既不重新赋值
    /// `songs` 也不推进 `songMutationGeneration`。拷回必须保持这一点,
    /// 否则 tvOS 的 `reloadFromDisk()` 会在每次失败装载后白白发布一次新数组。
    func testUnreadableSnapshotReloadDoesNotBumpTheSongMutationGeneration() throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // 用一个目录顶替 `library-cache.json`: 存在但读不出内容。
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("library-cache.json"),
            withIntermediateDirectories: true
        )

        let library = MusicLibrary(storageDirectory: directory)
        XCTAssertTrue(library.songs.isEmpty)
        let generationAfterInit = library.songMutationGenerationForMaintenance

        library.reloadFromDisk()

        XCTAssertEqual(
            library.songMutationGenerationForMaintenance,
            generationAfterInit,
            "an unreadable snapshot must not republish the songs array"
        )
        XCTAssertTrue(library.songs.isEmpty)
        XCTAssertTrue(library.isReady)
    }

    // MARK: - T5 discarded preparation

    func testDiscardedPreparationLeavesTheStoreAndCachesUntouched() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)

        // 只保留可移植 JSON 与设备本地账本: 新目录里的 SQLite 迁移版本落后 (0)。
        let target = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: target) }
        for name in ["library-cache.json", "library-device-local-excluded-songs.json"] {
            let source = fixture.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try FileManager.default.copyItem(at: source, to: target.appendingPathComponent(name))
        }

        let storePath = target.appendingPathComponent("library-songs.sqlite").path
        let preparation = await MusicLibrary.prepareStartup(storageDirectory: target)

        // 未发布: 迁移版本、SQLite 行、派生缓存都不能被改动。
        let inspector = try IncrementalSongStore(path: storePath)
        XCTAssertEqual(
            try inspector.startupState().completedMigrationVersion,
            0,
            "a discarded preparation must not mark the store migration complete"
        )
        XCTAssertTrue(
            try inspector.loadSongs().isEmpty,
            "a discarded preparation must not write rows into the store"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("library-startup-cache.plist").path
            ),
            "a discarded preparation must not write the startup cache"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: target.appendingPathComponent("library-derived-index.plist").path
            ),
            "a discarded preparation must not write the derived index cache"
        )

        // 发布之后, 同样的耐久写入必须真的发生。
        let library = MusicLibrary.makePreparing(storageDirectory: target)
        library.publish(preparation)
        XCTAssertFalse(library.songs.isEmpty)
        XCTAssertEqual(
            try IncrementalSongStore(path: storePath).startupState().completedMigrationVersion,
            6,
            "publication must run the deferred store migration"
        )
    }
}
