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
        journalCatchUpMaximumRows: Int? = nil,
        inputs: LibraryCatalogMirrorInputs? = LibraryCatalogMirrorTests.defaultInputs,
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
        if let journalCatchUpMaximumRows { environment.journalCatchUpMaximumRows = journalCatchUpMaximumRows }
        environment.importBatchHook = hook
        environment.verificationTimeout = .seconds(10)
        environment.log = { print("[mirror] \($0)") }
        let mirror = LibraryCatalogMirror(environment: environment, events: events)
        if let inputs { mirror.updateInputs(inputs) }
        return mirror
    }

    /// 持有方发布之前就启动时预估的输入:与 `defaultInputs` 相同,只是源的名字还不知道。
    static var earlyInputs: LibraryCatalogMirrorInputs {
        var inputs = defaultInputs
        inputs.sourceNames = nil
        return inputs
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

    /// 旧库的变更流水接不上时(这里把上限压到 0;没有流水的旧版本写过旧库的情形在 PrimuseKit 的流水测试里)
    /// 照旧整库对账。
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

        let second = makeMirror(batchSize: 5, journalCatchUpMaximumRows: 0)
        second.start()
        await second.waitUntilIdle()
        XCTAssertEqual(second.statistics.journalCatchUps, 0)
        XCTAssertEqual(second.statistics.journalCatchUpFallbacks, 1)
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

    // MARK: - Journal catch-up

    /// 目录没开着的时候旧库写过:按旧库的变更流水只补改过的行,不整库对账;结果与旧库逐行相同。
    func testACatalogBehindTheStoreCatchesUpFromTheJournalWithoutAResync() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        var songs = Self.makeSongs(24)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 5)
        first.start()
        await first.waitUntilIdle()
        await first.stop()

        // 三个修订号:改两首加三首;删一首;一首改名又改标题。
        songs[3].title = "Retitled 3"
        songs[10].albumTitle = "Moved Album"
        let added = Self.makeSongs(3, prefix: "late")
        try store.apply(upserts: [songs[3], songs[10]] + added, deletingIDs: [])
        try store.apply(upserts: [], deletingIDs: [songs[7].id])
        var renamed = songs[5]
        renamed.id = "renamed-5"
        renamed.title = "Renamed 5"
        let last = try store.apply(upserts: [renamed], deletingIDs: [], renaming: [songs[5].id: renamed.id])

        let second = makeMirror(batchSize: 5)
        second.start()
        await second.waitUntilIdle()
        let statistics = second.statistics
        XCTAssertEqual(statistics.journalCatchUps, 1)
        XCTAssertEqual(statistics.journalCatchUpRows, 5 + 1 + 2)
        XCTAssertEqual(statistics.journalCatchUpFallbacks, 0)
        XCTAssertEqual(statistics.resyncs, 0, "the journal covers the gap: no full re-sync")
        XCTAssertEqual(statistics.importRuns, 0)
        let catalog = try XCTUnwrap(second.readableCatalog)
        XCTAssertEqual(try catalog.songCount(.everything), 26)
        XCTAssertEqual(try catalog.song(id: songs[3].id)?.title, "Retitled 3")
        XCTAssertNil(try catalog.song(id: songs[7].id))
        XCTAssertNil(try catalog.song(id: songs[5].id))
        XCTAssertEqual(try catalog.song(id: renamed.id)?.title, "Renamed 5")
        XCTAssertEqual(second.mirroredStoreRevision, last)
        try assertCatalogMatchesStore(catalog)

        // 追上之后照常跟写:修订号接着往下走。
        var later = songs[1]
        later.title = "Written after the catch-up"
        let revision = try store.apply(upserts: [later], deletingIDs: [])
        second.enqueueApply(upserts: [later], deletingIDs: [], storeRevision: revision)
        await second.waitUntilIdle()
        XCTAssertEqual(second.mirroredStoreRevision, revision)
        XCTAssertEqual(second.statistics.resyncs, 0)
        try assertCatalogMatchesStore(try XCTUnwrap(second.readableCatalog))
        await second.stop()
    }

    /// 打开、按流水追上都不等整库那道门(App 在后台、温度高):门关着启动,目录照样追上、可读。
    /// 流水接不上、要整库对账时才等门开,这期间目录对谁都不可读。
    func testOpeningAndCatchingUpDoNotWaitForTheBulkWorkGate() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        let songs = Self.makeSongs(12)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 4)
        first.start()
        await first.waitUntilIdle()
        await first.stop()
        var edited = songs[2]
        edited.title = "Edited in the background"
        let revision = try store.apply(upserts: [edited], deletingIDs: [])

        let blocked = InteractionFlag()
        blocked.set()
        let second = makeMirror(batchSize: 4, bulkWorkBlocked: blocked)
        second.start()
        let caughtUp = try await Self.waitForCatalog(second, timeout: .seconds(5)) {
            try $0.song(id: edited.id)?.title == edited.title
        }
        XCTAssertTrue(caughtUp, "opening and the journal catch-up must not wait for the bulk-work gate")
        XCTAssertEqual(second.mirroredStoreRevision, revision)
        XCTAssertEqual(second.statistics.journalCatchUps, 1)
        await second.stop()

        var again = songs[4]
        again.title = "Needs a full re-sync"
        try store.apply(upserts: [again], deletingIDs: [])
        let third = makeMirror(batchSize: 4, bulkWorkBlocked: blocked, journalCatchUpMaximumRows: 0)
        third.start()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNil(third.readableCatalog, "a catalog that still needs the full re-sync is not readable")
        XCTAssertNil(third.caughtUpCatalog)
        XCTAssertEqual(third.statistics.resyncs, 0, "the full re-sync keeps its gate")
        blocked.set(false)
        await third.waitUntilIdle()
        XCTAssertEqual(third.statistics.resyncs, 1)
        XCTAssertEqual(try XCTUnwrap(third.readableCatalog).song(id: again.id)?.title, again.title)
        await third.stop()
    }

    // MARK: - Started before the owner is ready (cold launch)

    /// 一个迁移好的目录,之后旧库又往前走了一个修订号(目录没跟)。返回目录停在的修订号与改过的那首。
    private func makeCatalogOneRevisionBehind(songCount: Int = 12) async throws -> (mirrored: Int64, store: Int64, edited: Song) {
        let store = try IncrementalSongStore(path: storeURL.path)
        let songs = Self.makeSongs(songCount)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 4)
        first.start()
        await first.waitUntilIdle()
        let mirrored = try XCTUnwrap(first.mirroredStoreRevision)
        await first.stop()
        var edited = songs[2]
        edited.title = "Edited while the catalog was closed"
        let revision = try store.apply(upserts: [edited], deletingIDs: [])
        return (mirrored, revision, edited)
    }

    /// 持有方还没发布就启动(冷启动):目录打开、按流水追上,按 id 的读法拿得到;列表读者、可读事件等发布。
    func testAnEarlyStartedCatalogCatchesUpButStaysHiddenFromListReadersUntilTheOwnerIsReady() async throws {
        let behind = try await makeCatalogOneRevisionBehind()
        let readability = OSAllocatedReadabilityLog()
        let mirror = makeMirror(batchSize: 4, inputs: nil) { event in
            if case .readability(let readable) = event { readability.append(readable) }
        }
        mirror.start(beforeOwnerIsReady: LibraryCatalogMirrorEarlyStart(
            inputs: Self.earlyInputs, storeIsWhatTheModelLoads: { true }
        ))
        await mirror.waitUntilIdle()
        XCTAssertNil(mirror.readableCatalog, "list readers wait for the owner")
        let caughtUp = try XCTUnwrap(mirror.caughtUpCatalog, "by-id readers get the catalog once it has caught up")
        XCTAssertEqual(try caughtUp.song(id: behind.edited.id)?.title, behind.edited.title)
        XCTAssertEqual(mirror.mirroredStoreRevision, behind.store)
        XCTAssertEqual(mirror.statistics.journalCatchUps, 1)
        XCTAssertEqual(readability.values, [], "no readability event before the owner is ready")

        // 发布:交上正式的输入(只多了源的名字),放给读者。
        mirror.updateInputs(Self.defaultInputs)
        mirror.ownerBecameReady()
        await mirror.waitUntilIdle()
        XCTAssertNotNil(mirror.readableCatalog)
        XCTAssertEqual(readability.values, [true])
        XCTAssertEqual(mirror.statistics.groupingRebuilds, 0)
        XCTAssertEqual(mirror.statistics.resyncs, 0)
        try assertCatalogMatchesStore(try XCTUnwrap(mirror.readableCatalog))
        await mirror.stop()
    }

    /// 预估的输入与目录里存着的不一样,或者内存模型这一次不是原样装旧库:提前启动的目录一个字节都不写、
    /// 对谁都不可读,等发布时的正式输入。
    func testAnEarlyStartWhoseInputsDoNotMatchLeavesTheCatalogAloneUntilTheOwnerIsReady() async throws {
        let behind = try await makeCatalogOneRevisionBehind()
        var otherGrouping = Self.earlyInputs
        otherGrouping.grouping = LibraryGroupingConfiguration(unknownArtist: "Someone Else")
        var otherSources = Self.earlyInputs
        otherSources.disabledSourceIDs = ["src-b"]
        let cases: [(String, LibraryCatalogMirrorEarlyStart)] = [
            ("grouping", LibraryCatalogMirrorEarlyStart(inputs: otherGrouping, storeIsWhatTheModelLoads: { true })),
            ("disabled sources", LibraryCatalogMirrorEarlyStart(inputs: otherSources, storeIsWhatTheModelLoads: { true })),
            ("store", LibraryCatalogMirrorEarlyStart(inputs: Self.earlyInputs, storeIsWhatTheModelLoads: { false })),
        ]
        for (name, early) in cases {
            let mirror = makeMirror(batchSize: 4, inputs: nil)
            mirror.start(beforeOwnerIsReady: early)
            await mirror.waitUntilIdle()
            XCTAssertNil(mirror.caughtUpCatalog, name)
            XCTAssertNil(mirror.readableCatalog, name)
            XCTAssertEqual(mirror.mirroredStoreRevision, behind.mirrored, "\(name): the catalog was not written")
            XCTAssertEqual(mirror.statistics.journalCatchUps, 0, name)
            guard name == "store" else {
                await mirror.stop()
                continue
            }
            // 发布:正式的输入到了才追。
            mirror.updateInputs(Self.defaultInputs)
            mirror.ownerBecameReady()
            await mirror.waitUntilIdle()
            XCTAssertEqual(mirror.statistics.journalCatchUps, 1)
            XCTAssertEqual(mirror.statistics.resyncs, 0)
            XCTAssertEqual(mirror.mirroredStoreRevision, behind.store)
            try assertCatalogMatchesStore(try XCTUnwrap(mirror.readableCatalog))
            await mirror.stop()
        }
    }

    /// 第一次迁移是整库的活:提前启动时连目录文件都不建,等发布。
    func testAnEarlyStartDoesNoBulkWorkBeforeTheOwnerIsReady() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        try store.replaceAll(with: Self.makeSongs(8))
        let mirror = makeMirror(batchSize: 4, inputs: nil)
        mirror.start(beforeOwnerIsReady: LibraryCatalogMirrorEarlyStart(
            inputs: Self.earlyInputs, storeIsWhatTheModelLoads: { true }
        ))
        try await Task.sleep(for: .milliseconds(700))
        XCTAssertFalse(FileManager.default.fileExists(atPath: catalogURL.path))
        XCTAssertEqual(mirror.statistics.importRuns, 0)
        XCTAssertNil(mirror.caughtUpCatalog)

        mirror.updateInputs(Self.defaultInputs)
        mirror.ownerBecameReady()
        await mirror.waitUntilIdle()
        XCTAssertEqual(mirror.statistics.importsCompleted, 1)
        try assertCatalogMatchesStore(try XCTUnwrap(mirror.readableCatalog))
        await mirror.stop()
    }

    /// 不变量:目录落后旧库期间(正在按流水追)按 id 的读法拿不到它,读不到旧值;给出来的那一刻已经是
    /// 旧库的样子。
    func testByIDReadersNeverGetACatalogThatIsBehindTheStore() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        let songs = Self.makeSongs(40)
        try store.replaceAll(with: songs)
        let first = makeMirror(batchSize: 4)
        first.start()
        await first.waitUntilIdle()
        await first.stop()
        // 落后三十个修订号,每个改一首。
        var lastRevision: Int64 = 0
        for index in 0..<30 {
            var edited = songs[index]
            edited.title = "New title \(index)"
            lastRevision = try store.apply(upserts: [edited], deletingIDs: [])
        }

        // 增量写入为滑动让路:追的过程拉长到看得见。
        let scrolling = InteractionFlag()
        scrolling.set()
        let mirror = makeMirror(batchSize: 4, scrolling: scrolling, maximumApplyPause: .milliseconds(30), inputs: nil)
        mirror.start(beforeOwnerIsReady: LibraryCatalogMirrorEarlyStart(
            inputs: Self.earlyInputs, storeIsWhatTheModelLoads: { true }
        ))
        var sawBehind = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if let catalog = mirror.caughtUpCatalog {
                XCTAssertEqual(mirror.mirroredStoreRevision, lastRevision, "handed out only at the store's revision")
                for index in 0..<30 {
                    XCTAssertEqual(try catalog.song(id: songs[index].id)?.title, "New title \(index)")
                }
                break
            }
            sawBehind = true
            XCTAssertNil(mirror.readableCatalog)
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(sawBehind, "the catalog was not handed out while it was behind")
        try assertCatalogMatchesStore(try XCTUnwrap(mirror.caughtUpCatalog))
        XCTAssertEqual(mirror.statistics.journalCatchUps, 1)
        await mirror.stop()
    }

    /// 进后台、内存警告时放掉目录各连接的缓存:放完照常读写。
    func testReleasingMemoryKeepsTheCatalogWorking() async throws {
        let store = try IncrementalSongStore(path: storeURL.path)
        let songs = Self.makeSongs(12)
        try store.replaceAll(with: songs)
        let mirror = makeMirror(batchSize: 4)
        mirror.start()
        await mirror.waitUntilIdle()
        let catalog = try XCTUnwrap(mirror.readableCatalog)
        XCTAssertEqual(try catalog.song(id: songs[3].id)?.title, songs[3].title)

        mirror.releaseMemory()
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while mirror.statistics.memoryReleases == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(mirror.statistics.memoryReleases, 1)
        XCTAssertEqual(try catalog.song(id: songs[3].id)?.title, songs[3].title)
        var edited = songs[4]
        edited.title = "Written after the release"
        let revision = try store.apply(upserts: [edited], deletingIDs: [])
        mirror.enqueueApply(upserts: [edited], deletingIDs: [], storeRevision: revision)
        await mirror.waitUntilIdle()
        try assertCatalogMatchesStore(try XCTUnwrap(mirror.readableCatalog))
        await mirror.stop()
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

/// 测试里跨线程收可读事件。
final class OSAllocatedReadabilityLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [Bool] = []

    var values: [Bool] { lock.withLock { log } }

    func append(_ readable: Bool) {
        lock.withLock { log.append(readable) }
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
