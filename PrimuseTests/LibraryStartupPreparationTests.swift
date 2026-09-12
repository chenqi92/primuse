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

/// `persistNowAndWait` 的完成记录器。测试要在发布之前断言"还没完成",
/// 转义闭包同样不能捕获可变局部变量。
@MainActor
private final class PersistenceBarrierRecorder {
    private(set) var isCompleted = false
    private(set) var succeeded = false
    func complete(_ outcome: Result<Void, AppleTVTransferFailure>) {
        isCompleted = true
        if case .success = outcome { succeeded = true }
    }
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

    /// 薄壳: 实现是文件末尾的 `assertLibraryStartupParity`, Stage 2 的大库
    /// 基准复用同一套对比。
    private func assertParity(
        synchronous: MusicLibrary,
        prepared: MusicLibrary,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertLibraryStartupParity(
            synchronous: synchronous,
            prepared: prepared,
            file: file,
            line: line
        )
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

    // MARK: - T6 S2 完整性: 所有顶层突变入口

    /// 只有九个入口排队时, 其余顶层突变都落在空的 `.preparing` 模型上, 然后
    /// 被 `loadSnapshot` 的整体拷回抹掉, 补写再把丢失固化到磁盘。这里覆盖歌单
    /// 创建 / 喜欢 / 播放历史 / 评分评论 / 封面覆盖, 外加两个"不排队而是对账"
    /// 的配置 setter。
    func testQueuedTopLevelMutationsSurvivePublicationIncludingConfiguration() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }

        let sourceA = "source-a"
        let sourceB = "source-b"
        let a1 = Self.makeSong(id: "a1", sourceID: sourceA)
        let a2 = Self.makeSong(id: "a2", sourceID: sourceA)
        let b1 = Self.makeSong(id: "b1", sourceID: sourceB)
        let seed = MusicLibrary(storageDirectory: fixture)
        seed.addSongs([a1, a2], affectedSourceIDs: [sourceA])
        seed.addSongs([b1], affectedSourceIDs: [sourceB])
        guard case .success = await seed.persistNowAndWait() else {
            throw XCTSkip("The isolated library did not finish persistence")
        }

        let library = MusicLibrary.makePreparing(storageDirectory: fixture)
        XCTAssertTrue(library.songs.isEmpty)

        let albumOwner = LibraryArtworkOwner(kind: .album, id: "album-queued")
        // 以下每一条都作用在空库上; 没有排队的话发布拷回会把它们全部抹掉。
        let created = library.createPlaylist(name: "Queued", songIDs: [a1.id, b1.id])
        library.setLiked(songID: a1.id, isLiked: true, propagatesServerMutation: false)
        library.toggleLiked(songID: a2.id)
        library.recordPlayback(of: a1.id)
        library.updateLibraryReview(for: .song(a1.id), rating: 4, comment: "  排队的评论  ")
        XCTAssertTrue(
            library.setArtwork(for: albumOwner, to: a1),
            "排队的封面覆盖必须被接受 (与 S1 下耐久账本返回 true 的约定一致)"
        )
        library.updateDisabledSourceIDs([sourceB])

        // 排队期间库不动, 但创建型入口的返回值当场可用。
        XCTAssertFalse(created.id.isEmpty)
        XCTAssertTrue(library.allPlaylists.isEmpty)
        XCTAssertTrue(library.recentPlaybackSongIDsForSync.isEmpty)
        XCTAssertNil(library.libraryReview(for: .song(a1.id)))
        XCTAssertEqual(library.readiness, .preparing)

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: fixture)
        library.publish(preparation)

        XCTAssertEqual(library.readiness, .ready)
        XCTAssertTrue(
            library.allPlaylists.contains(where: { $0.id == created.id }),
            "createPlaylist 返回的歌单必须以同一个 id 出现在发布后的库里"
        )
        XCTAssertEqual(library.rawSongIDs(forPlaylist: created.id), [a1.id, b1.id])
        XCTAssertTrue(library.isLiked(songID: a1.id))
        XCTAssertTrue(library.isLiked(songID: a2.id), "toggleLiked 的取反要在发布后再读一次状态")
        XCTAssertEqual(library.recentPlaybackSongIDsForSync, [a1.id])
        XCTAssertEqual(library.libraryReview(for: .song(a1.id))?.rating, 4)
        XCTAssertEqual(library.libraryReview(for: .song(a1.id))?.comment, "排队的评论")
        XCTAssertEqual(library.artworkOverride(for: albumOwner)?.mode, .selectedSong)
        // 配置 setter 不排队: 发布时与准备结果对账, 可见缓存按最新值重建。
        XCTAssertEqual(library.disabledSourceIDs, [sourceB])
        XCTAssertEqual(library.visibleSongs.map(\.id).sorted(), [a1.id, a2.id])
        XCTAssertNil(library.visibleSong(id: b1.id), "被禁用源的歌不能出现在可见缓存里")

        guard case .success = await library.persistNowAndWait() else {
            XCTFail("The published library did not finish persistence")
            return
        }
    }

    // MARK: - Stage 2 T7 有界就绪等待 `whenReady(timeout:)`

    /// 已发布的库立即返回 true, 不会为了一个已经满足的条件多睡一次。
    func testBoundedWhenReadyReturnsImmediatelyForAPublishedLibrary() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary(storageDirectory: directory)
        XCTAssertTrue(library.isReady)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let isReady = await library.whenReady(timeout: .seconds(8))
        XCTAssertTrue(isReady)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            1,
            "已就绪时不允许真的去等超时"
        )
    }

    /// 仍在准备中时超时返回 false, 而且超时的等待者必须已经从登记表里摘掉 ——
    /// 否则随后的发布会对同一条续体 resume 两次并直接崩溃。
    func testBoundedWhenReadyTimesOutWhileTheLibraryIsStillPreparing() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let isReady = await library.whenReady(timeout: .milliseconds(100))
        XCTAssertFalse(isReady)
        XCTAssertEqual(library.readiness, .preparing)

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: directory)
        library.publish(preparation)
        XCTAssertTrue(library.isReady)
    }

    /// 超时之前发布 → 返回 true, 并且等待者立刻被唤醒(不是等满超时)。
    func testBoundedWhenReadyReturnsTrueWhenPublicationArrivesFirst() async throws {
        let fixture = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: fixture) }
        try await Self.populate(fixture)

        let library = MusicLibrary.makePreparing(storageDirectory: fixture)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let waiter = Task { @MainActor in
            await library.whenReady(timeout: .seconds(30))
        }
        let preparation = await MusicLibrary.prepareStartup(storageDirectory: fixture)
        library.publish(preparation)

        let isReady = await waiter.value
        XCTAssertTrue(isReady)
        XCTAssertFalse(library.songs.isEmpty, "发布之后等待者看到的必须是真实的库")
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            10,
            "发布先到时不能继续睡到超时"
        )
    }

    /// 调用方被取消(Siri 的 Task 被拆、视图的 `.task` 随视图消失)时必须当场
    /// 返回, 而不是白等满超时; 而且取消的一方要把自己那条续体摘走, 随后的
    /// 发布不能再 resume 它一次(那是直接崩溃)。
    func testBoundedWhenReadyReturnsPromptlyWhenTheCallerIsCancelled() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let startedAt = ProcessInfo.processInfo.systemUptime
        let waiter = Task { @MainActor in
            await library.whenReady(timeout: .seconds(30))
        }
        // 先让等待者真的挂上去, 再取消 —— 否则测的是"进门前就已取消"那条路径。
        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()

        let isReady = await waiter.value
        XCTAssertFalse(isReady)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            10,
            "被取消的等待者不能继续睡到超时"
        )
        XCTAssertEqual(library.readiness, .preparing)

        // 取消的一方已经摘走自己那条续体, 所以发布是安全的。
        let preparation = await MusicLibrary.prepareStartup(storageDirectory: directory)
        library.publish(preparation)
        XCTAssertTrue(library.isReady)
    }

    /// 进门前就已取消的调用方同样要立刻返回(`onCancel` 可能早于登记)。
    func testBoundedWhenReadyReturnsImmediatelyForAnAlreadyCancelledCaller() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        let waiter = Task { @MainActor in
            // 先取消再进入等待。
            await Task.yield()
            return await library.whenReady(timeout: .seconds(30))
        }
        waiter.cancel()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let isReady = await waiter.value
        XCTAssertFalse(isReady)
        XCTAssertLessThan(
            ProcessInfo.processInfo.systemUptime - startedAt,
            10,
            "已取消的调用方不能真的去等超时"
        )
        XCTAssertEqual(library.readiness, .preparing)
    }

    // MARK: - T7 `.preparing` 期间的耐久屏障

    /// `.preparing` 时 songStore 还是 nil、S1 又拦下快照写入, 旧实现会在一个
    /// 字节都没写的情况下返回 .success, 调用方据此提交扫描游标 / 传输检查点。
    func testPersistNowAndWaitWaitsForPublicationBeforeReportingSuccess() async throws {
        let directory = try Self.makeStorageDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let snapshotURL = directory.appendingPathComponent("library-cache.json")

        let library = MusicLibrary.makePreparing(storageDirectory: directory)
        library.addSongs([Self.makeSong(id: "queued", sourceID: "source-a")])

        let recorder = PersistenceBarrierRecorder()
        let barrier = Task { @MainActor in
            recorder.complete(await library.persistNowAndWait())
        }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertFalse(
            recorder.isCompleted,
            "耐久屏障不能在发布之前就返回 —— 排队的行此刻还不在模型里"
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: snapshotURL.path),
            "library-cache.json must not be written while preparing"
        )

        let preparation = await MusicLibrary.prepareStartup(storageDirectory: directory)
        library.publish(preparation)
        await barrier.value

        XCTAssertTrue(recorder.isCompleted)
        XCTAssertTrue(recorder.succeeded, "发布之后屏障必须真的写完快照再返回 .success")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshotURL.path))
        XCTAssertEqual(library.songs.map(\.id), ["queued"])
        let persisted = String(decoding: try Data(contentsOf: snapshotURL), as: UTF8.self)
        XCTAssertTrue(
            persisted.contains("\"queued\""),
            "屏障返回成功时, 排队突变提交的行必须已经在磁盘上"
        )
    }
}

/// Stage 1 的发布结果对比。抽成模块级函数, 让 Stage 2 的大库基准
/// (`LibraryStartupHarnessTests`) 复用同一套断言而不必抄一遍。
@MainActor
func assertLibraryStartupParity(
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
