import Foundation
import PrimuseKit
import XCTest
#if SWIFT_PACKAGE
@testable import CatalogAppCheck
#else
@testable import Primuse
#endif

/// 目录镜像本身(不经 `MusicLibrary`):首次迁移、被杀后续导、漂移对账、增量顺序与合并、
/// 整份替换、队列溢出、写失败。旧库用真的 `IncrementalSongStore`。
final class LibraryCatalogMirrorTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryCatalogMirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var storeURL: URL { directory.appendingPathComponent("library-songs.sqlite") }
    private var catalogURL: URL { directory.appendingPathComponent("library-catalog.sqlite") }

    static func makeSongs(_ count: Int, prefix: String = "song", sources: [String] = ["src-a", "src-b"]) -> [Song] {
        (0..<count).map { index in
            let sourceID = sources[index % sources.count]
            return Song(
                id: "\(prefix)-\(index)",
                title: "Title \(index)",
                albumTitle: "Album \(index / 4)",
                artistName: index % 5 == 0 ? "Singer \(index % 3)、Guest \(index % 2)" : "Singer \(index % 3)",
                albumArtistName: "Singer \(index % 3)",
                trackNumber: index % 4 + 1,
                discNumber: 1,
                duration: 120 + Double(index),
                fileFormat: .flac,
                filePath: "/Music/\(sourceID)/Album \(index / 4)/\(index).flac",
                sourceID: sourceID,
                genre: index % 2 == 0 ? "Rock" : "Jazz",
                year: 2000 + index % 7,
                coverArtFileName: index % 4 == 0 ? "cover-\(index / 4).jpg" : nil
            )
        }
    }

    private func makeMirror(
        batchSize: Int = LibraryScale.importBatchSize,
        maximumQueuedSongs: Int = 50_000,
        hook: (@Sendable (LibraryCatalogImportProgress) -> Bool)? = nil,
        bulkWorkBlocked: InteractionFlag? = nil,
        scrolling: InteractionFlag? = nil,
        maximumApplyPause: Duration = .seconds(1),
        startDelay: Duration = .zero,
        events: @escaping @Sendable (LibraryCatalogMirrorEvent) -> Void = { _ in }
    ) -> LibraryCatalogMirror {
        var environment = LibraryCatalogMirrorEnvironment(catalogURL: catalogURL, storeURL: storeURL)
        if let bulkWorkBlocked { environment.interactionGate = { !bulkWorkBlocked.isSet } }
        if let scrolling { environment.incrementalApplyGate = { !scrolling.isSet } }
        environment.incrementalApplyMaximumPause = maximumApplyPause
        environment.startDelay = startDelay
        environment.resumeDelay = .zero
        environment.importBatchSize = batchSize
        environment.applyChunkSize = max(2, batchSize)
        environment.maximumQueuedSongs = maximumQueuedSongs
        environment.importBatchHook = hook
        environment.verificationTimeout = .seconds(10)
        environment.log = { print("[mirror] \($0)") }
        let mirror = LibraryCatalogMirror(environment: environment, events: events)
        mirror.updateInputs(Self.defaultInputs)
        return mirror
    }

    static let defaultInputs = LibraryCatalogMirrorInputs(
        grouping: LibraryGroupingConfiguration(unknownArtist: "Unknown Artist"),
        disabledSourceIDs: [],
        sourceNames: ["src-a": "Alpha", "src-b": "Beta"]
    )

    /// 目录与旧库逐行一致:同一批 id、同样的库内顺序、同样的内容。
    private func assertCatalogMatchesStore(
        _ catalog: LibraryCatalog,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let scanner = try IncrementalSongStoreScanner(path: storeURL.path)
        var storeSongs: [Song] = []
        var cursor: (orderKey: Int64, id: String)?
        while true {
            let rows = try scanner.rows(after: cursor, limit: 500)
            guard let last = rows.last else { break }
            storeSongs.append(contentsOf: rows.map(\.song))
            cursor = (last.orderKey, last.song.id)
        }
        var catalogIDs: [String] = []
        try catalog.forEachSongIdentity(.everything) { _, id, _ in
            catalogIDs.append(id)
            return true
        }
        XCTAssertEqual(catalogIDs, storeSongs.map(\.id), "library order", file: file, line: line)
        let catalogSongs = try catalog.songs(ids: storeSongs.map(\.id))
        XCTAssertEqual(catalogSongs.map(\.title), storeSongs.map(\.title), "content", file: file, line: line)
        XCTAssertEqual(catalogSongs.map(\.filePath), storeSongs.map(\.filePath), "paths", file: file, line: line)
    }

    // MARK: - Migration

    func testFirstMigrationImportsGroupsAndRecordsTheStoreRevision() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        let revision = try store.replaceAll(with: Self.makeSongs(40))
        let mirror = makeMirror(batchSize: 7)
        mirror.start()
        await mirror.waitUntilIdle()
        let catalog = try XCTUnwrap(mirror.readableCatalog, "catalog should be readable after migration")
        XCTAssertEqual(try catalog.songCount(.everything), 40)
        XCTAssertFalse(try catalog.groupingNeedsRebuild)
        XCTAssertGreaterThan(try catalog.albumKeys(visibleOnly: true).count, 0)
        XCTAssertEqual(mirror.mirroredStoreRevision, revision)
        XCTAssertEqual(try catalog.mirrorMetadata("storeRevision"), String(revision))
        XCTAssertEqual(mirror.statistics.importsCompleted, 1)
        // 迁移只建必需的索引;艺人、专辑、文件名的排序索引由镜像在空闲时补上。
        XCTAssertFalse(try catalog.hasPendingSortIndexes(), "the mirror builds the deferred sort indexes once idle")
        try assertCatalogMatchesStore(catalog)
        await mirror.stop()
    }

    func testMigrationResumesFromTheCursorAfterTheProcessIsKilled() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(30))
        let batches = OSAllocatedCounter()
        let killed = makeMirror(batchSize: 5, hook: { _ in batches.increment() < 1 })
        killed.start()
        await killed.waitUntilIdle()
        await killed.stop()
        XCTAssertEqual(killed.statistics.importsCompleted, 0)
        XCTAssertNil(killed.readableCatalog)
        do {
            let partial = try LibraryCatalog(path: catalogURL.path)
            XCTAssertFalse(try partial.hasCompletedImport)
        }

        let resumed = makeMirror(batchSize: 5)
        resumed.start()
        await resumed.waitUntilIdle()
        XCTAssertEqual(resumed.statistics.importsCompleted, 1)
        XCTAssertEqual(resumed.statistics.lastImportStartedAt, 10, "the second run continues after the two committed batches")
        let catalog = try XCTUnwrap(resumed.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), 30)
        try assertCatalogMatchesStore(catalog)
        await resumed.stop()
    }

    // MARK: - Drift

    func testDriftFromAnOlderBuildResyncsByStreamingWithoutReimport() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        var songs = Self.makeSongs(24)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 5)
        first.start()
        await first.waitUntilIdle()
        await first.stop()

        // 「旧版本」只写旧库:改两首、加三首、删一首。
        songs[3].title = "Retitled 3"
        songs[10].albumTitle = "Moved Album"
        let added = Self.makeSongs(3, prefix: "late")
        try store.apply(upserts: [songs[3], songs[10]] + added, deletingIDs: [songs[7].id])

        let second = makeMirror(batchSize: 5)
        second.start()
        await second.waitUntilIdle()
        XCTAssertEqual(second.statistics.resyncs, 1)
        XCTAssertEqual(second.statistics.importRuns, 0, "drift is repaired without a re-import")
        let catalog = try XCTUnwrap(second.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), 26)
        XCTAssertEqual(try catalog.song(id: songs[3].id)?.title, "Retitled 3")
        XCTAssertNil(try catalog.song(id: songs[7].id))
        XCTAssertEqual(second.mirroredStoreRevision, try store.startupState().contentRevision)
        try assertCatalogMatchesStore(catalog)
        await second.stop()
    }

    func testResyncFallsBackToImportWhenTheStoreWasReordered() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        let songs = Self.makeSongs(20)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 6)
        first.start()
        await first.waitUntilIdle()
        await first.stop()

        try store.replaceAll(with: Array(songs.reversed()))
        let second = makeMirror(batchSize: 6)
        second.start()
        await second.waitUntilIdle()
        XCTAssertEqual(second.statistics.resyncFallbacksToImport, 1)
        XCTAssertEqual(second.statistics.importsCompleted, 1)
        try assertCatalogMatchesStore(try XCTUnwrap(second.readableCatalog))
        await second.stop()
    }

    // MARK: - Dual-write

    /// 已经迁移过的目录不等启动延迟,打开就可读;只有第一次迁移才等。
    func testMigratedCatalogOpensWithoutTheStartDelay() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(6))
        do {
            let first = makeMirror(batchSize: 4)
            first.start()
            await first.waitUntilIdle()
            XCTAssertNotNil(first.readableCatalog)
            await first.stop()
        }
        let second = makeMirror(batchSize: 4, startDelay: .seconds(30))
        second.start()
        let startedAt = ContinuousClock.now
        while second.readableCatalog == nil, ContinuousClock.now - startedAt < .seconds(5) {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNotNil(second.readableCatalog, "a migrated catalog must not wait for the first-migration start delay")
        await second.stop()
    }

    /// 迁移做完以后,整库那道门关着(App 在后台、温度高、扫描中)时增量照样写进目录。
    func testIncrementalWritesDoNotWaitForTheBulkWorkGate() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(6))
        let blocked = InteractionFlag()
        let mirror = makeMirror(batchSize: 4, bulkWorkBlocked: blocked)
        mirror.start()
        await mirror.waitUntilIdle()
        XCTAssertNotNil(mirror.readableCatalog)

        blocked.set()
        // 让巡检读到新的门(每 250 ms 问一次)。
        try await Task.sleep(for: .milliseconds(600))
        var added = Self.makeSongs(1, prefix: "bg")[0]
        added.title = "Written in the background"
        let revision = try store.apply(upserts: [added], deletingIDs: [])
        mirror.enqueueApply(upserts: [added], deletingIDs: [], storeRevision: revision)
        let found = try await Self.waitForCatalog(mirror, timeout: .seconds(5)) { try $0.song(id: added.id) != nil }
        XCTAssertTrue(found, "an incremental write must not wait for the bulk-work gate")
        XCTAssertEqual(mirror.mirroredStoreRevision, revision)
        await mirror.stop()
    }

    /// 用户正在滑时增量写入让一让,但最多让 `incrementalApplyMaximumPause`,之后照写。
    func testIncrementalWritesYieldToScrollingOnlyUpToTheCap() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(6))
        let scrolling = InteractionFlag()
        let mirror = makeMirror(batchSize: 4, scrolling: scrolling, maximumApplyPause: .milliseconds(1_500))
        mirror.start()
        await mirror.waitUntilIdle()

        scrolling.set()
        try await Task.sleep(for: .milliseconds(600))
        let added = Self.makeSongs(1, prefix: "scroll")[0]
        let revision = try store.apply(upserts: [added], deletingIDs: [])
        let startedAt = ContinuousClock.now
        mirror.enqueueApply(upserts: [added], deletingIDs: [], storeRevision: revision)
        let early = try await Self.waitForCatalog(mirror, timeout: .milliseconds(700)) { try $0.song(id: added.id) != nil }
        XCTAssertFalse(early, "the write waits while the user scrolls")
        let found = try await Self.waitForCatalog(mirror, timeout: .seconds(5)) { try $0.song(id: added.id) != nil }
        XCTAssertTrue(found, "the write lands after the pause cap even if scrolling continues")
        XCTAssertLessThan(ContinuousClock.now - startedAt, .seconds(4))
        await mirror.stop()
    }

    /// 轮询目录直到条件成立或超时。
    private static func waitForCatalog(
        _ mirror: LibraryCatalogMirror,
        timeout: Duration,
        _ condition: (LibraryCatalog) throws -> Bool
    ) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if let catalog = mirror.readableCatalog, try condition(catalog) { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    func testIncrementalWritesKeepTheStoreOrderAcrossDeleteAndReinsert() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(6))
        let mirror = makeMirror(batchSize: 4)
        mirror.start()
        await mirror.waitUntilIdle()

        // 同样的增量依次写旧库、排进镜像(与 `persistSongChanges` 的顺序一样)。
        func write(_ upserts: [Song], deleting: Set<String> = []) throws {
            let revision = try store.apply(upserts: upserts, deletingIDs: deleting)
            mirror.enqueueApply(upserts: upserts, deletingIDs: deleting, storeRevision: revision)
        }
        var extra = Self.makeSongs(3, prefix: "x")
        try write([extra[0], extra[1]])
        try write([], deleting: [extra[0].id])
        try write([extra[0]])
        extra[1].title = "Updated x1"
        try write([extra[1], extra[2]])
        try write([], deleting: ["song-2"])
        await mirror.waitUntilIdle()

        let catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.song(id: extra[1].id)?.title, "Updated x1")
        XCTAssertEqual(mirror.mirroredStoreRevision, try store.startupState().contentRevision)
        try assertCatalogMatchesStore(catalog)
        await mirror.stop()
    }

    func testReplacingTheStoreReimportsAndKeepsLaterWrites() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(8))
        let mirror = makeMirror(batchSize: 3)
        mirror.start()
        await mirror.waitUntilIdle()

        let replacement = Self.makeSongs(5, prefix: "snapshot")
        let replaced = try store.replaceAll(with: replacement)
        mirror.enqueueReplaceAll(storeRevision: replaced)
        let late = Self.makeSongs(2, prefix: "after")
        let revision = try store.apply(upserts: late)
        mirror.enqueueApply(upserts: late, deletingIDs: [], storeRevision: revision)
        await mirror.waitUntilIdle()

        let catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), 7)
        XCTAssertGreaterThanOrEqual(mirror.statistics.importsCompleted, 2)
        try assertCatalogMatchesStore(catalog)
        await mirror.stop()
    }

    func testQueueOverflowDropsTheQueueAndResyncs() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(10))
        let mirror = makeMirror(batchSize: 4, maximumQueuedSongs: 5)
        mirror.start()
        await mirror.waitUntilIdle()

        for chunk in 0..<4 {
            let songs = Self.makeSongs(3, prefix: "burst\(chunk)")
            let revision = try store.apply(upserts: songs)
            mirror.enqueueApply(upserts: songs, deletingIDs: [], storeRevision: revision)
        }
        await mirror.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(mirror.statistics.overflows, 1)
        let catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), 22)
        try assertCatalogMatchesStore(catalog)
        await mirror.stop()
    }

    func testAResyncWhileReadableKeepsReadersOnAFrozenView() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(30))
        let mirror = makeMirror(batchSize: 4, maximumQueuedSongs: 5)
        mirror.start()
        await mirror.waitUntilIdle()
        let before = mirror.statistics

        // 队列溢出,目录行数超过旧库一半:对账,不重新导入。
        for chunk in 0..<4 {
            let songs = Self.makeSongs(3, prefix: "burst\(chunk)")
            let revision = try store.apply(upserts: songs)
            mirror.enqueueApply(upserts: songs, deletingIDs: [], storeRevision: revision)
        }
        await mirror.waitUntilIdle()
        XCTAssertGreaterThan(mirror.statistics.resyncs, before.resyncs)
        XCTAssertEqual(mirror.statistics.importRuns, before.importRuns)
        // 对账期间读者读冻结视图,目录一直可读;对完账换回实时目录。
        XCTAssertGreaterThan(mirror.statistics.frozenReads, before.frozenReads)
        XCTAssertEqual(mirror.statistics.unreadableSpells, before.unreadableSpells)
        XCTAssertFalse(mirror.readsAreFrozen)
        let catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertFalse(catalog.isFrozenView)
        XCTAssertEqual(try catalog.songCount(.everything), 42)
        try assertCatalogMatchesStore(catalog)
        await mirror.stop()
    }

    func testAFailedCatalogWriteStopsMirroringAndLeavesTheRevisionBehind() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(4))
        let mirror = makeMirror()
        mirror.start()
        await mirror.waitUntilIdle()
        let before = mirror.mirroredStoreRevision

        // 目录存不进含 U+0000 的 id:模拟一次写失败。
        let broken = Song(id: "bad\u{0}id", title: "Broken", fileFormat: .mp3, filePath: "/b.mp3", sourceID: "src-a")
        let revision = try store.apply(upserts: [broken])
        mirror.enqueueApply(upserts: [broken], deletingIDs: [], storeRevision: revision)
        await mirror.waitUntilIdle()
        XCTAssertEqual(mirror.statistics.failures, 1)
        XCTAssertNil(mirror.readableCatalog)
        XCTAssertEqual(mirror.mirroredStoreRevision, before, "the next launch sees the drift and re-syncs")
        await mirror.stop()
    }

    // MARK: - Configuration

    func testDisabledSourcesAndGroupingInputsReachTheCatalog() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(12))
        let mirror = makeMirror()
        var inputs = Self.defaultInputs
        inputs.disabledSourceIDs = ["src-b"]
        mirror.updateInputs(inputs)
        mirror.start()
        await mirror.waitUntilIdle()
        var catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.visible), 6)
        XCTAssertEqual(try catalog.songCount(.everything), 12)

        inputs.disabledSourceIDs = []
        inputs.grouping = LibraryGroupingConfiguration(unknownArtist: "Unknown Artist", genreSeparators: [.slash, .comma])
        mirror.updateInputs(inputs)
        await mirror.waitUntilIdle()
        catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.visible), 12)
        XCTAssertEqual(catalog.groupingConfiguration, inputs.grouping)
        await mirror.stop()
    }
}

/// 测试里跨线程计数。
final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    /// 返回加一之前的值。
    func increment() -> Int {
        lock.withLock {
            defer { value += 1 }
            return value
        }
    }
}
