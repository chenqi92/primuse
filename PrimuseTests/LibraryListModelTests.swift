import Foundation
import PrimuseKit
import XCTest
#if SWIFT_PACKAGE
@testable import CatalogAppCheck
#else
@testable import Primuse
#endif

/// `LibraryListModel`:按页物化、窗口外放掉、目录变化后防抖重查、行缓存按行号失效。
/// 直接用 `LibraryCatalogHost` + 真的旧库,不经 `MusicLibrary`。
@MainActor
final class LibraryListModelTests: XCTestCase {
    private final class AlwaysAllowedOwner: LibraryCatalogOwner {
        var readableChanges: [Bool] = []
        func catalogWorkAllowed() -> Bool { true }
        func catalogReadabilityDidChange(_ readable: Bool) { readableChanges.append(readable) }
    }

    private var directory: URL!
    private var host: LibraryCatalogHost!
    private var store: IncrementalSongStore!
    private let owner = AlwaysAllowedOwner()

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LibraryListModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = try IncrementalSongStore(path: directory.appendingPathComponent("library-songs.sqlite").path)
        try store.replaceAll(with: LibraryCatalogMirrorTests.makeSongs(57))
        host = LibraryCatalogHost(directory: directory, startDelay: .zero, log: { print("[mirror] \($0)") })
        host.link.owner = owner
        host.mirror.updateInputs(LibraryCatalogMirrorTests.defaultInputs)
        host.mirror.start()
        await host.mirror.waitUntilIdle()
        await settleRevisions()
    }

    override func tearDown() async throws {
        await host?.mirror.stop()
        try? FileManager.default.removeItem(at: directory)
    }

    /// 镜像的事件经主线程合并发布:让出几轮,等修订号与列表模型的回调跑完。
    private func settleRevisions() async {
        for _ in 0..<5 { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(50))
    }

    private func write(_ upserts: [Song], deleting: Set<String> = []) throws {
        let revision = try store.apply(upserts: upserts, deletingIDs: deleting)
        host.mirror.enqueueApply(upserts: upserts, deletingIDs: deleting, storeRevision: revision)
    }

    private func waitUntil(_ condition: () -> Bool, timeout: Duration = .seconds(5)) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testCatalogBecomesReadableAndRevisionsAdvance() async throws {
        XCTAssertTrue(host.revisions.isReadable)
        XCTAssertNotNil(host.reader.isAvailable ? host.mirror.readableCatalog : nil)
        XCTAssertTrue(owner.readableChanges.contains(true))
        let before = host.revisions.membership
        try write(LibraryCatalogMirrorTests.makeSongs(2, prefix: "extra"))
        await host.mirror.waitUntilIdle()
        await settleRevisions()
        XCTAssertGreaterThan(host.revisions.membership, before)
        XCTAssertGreaterThan(host.revisions.token(forSourceID: "src-a"), 0)
    }

    func testPagesMaterializeOnDemandAndStayWithinTheWindow() async throws {
        let model = LibraryListModel(
            query: LibrarySongListQuery(.sorted(.title, .visibleMusic)),
            reader: host.reader,
            revisions: host.revisions,
            pageSize: 5,
            prefetchDistance: 5,
            debounce: .milliseconds(10)
        )
        model.activate()
        await waitUntil { !model.isLoading }
        let expectedCount = try await host.reader.songCount(.visibleMusic)
        XCTAssertEqual(model.count, expectedCount)
        XCTAssertEqual(model.count, 57)

        // 占位:第一次问拿不到,页到了才有。
        let first = await model.waitForItem(at: 0)
        XCTAssertNotNil(first)
        let sorted = try await host.reader.songRowList(order: .title)
        let expected = try await host.reader.songs(rowids: Array(sorted.rowids.prefix(3)))
        XCTAssertEqual(first?.id, expected.first??.id)

        // 往下翻:窗口跟着走,物化的行数有上限。
        for index in stride(from: 0, to: model.count, by: 4) {
            _ = await model.waitForItem(at: index)
        }
        let last = await model.waitForItem(at: model.count - 1)
        XCTAssertNotNil(last)
        // 窗口上下各 5 行 → 至多 3 页;修剪预算 (3 + 2) 页,外加一页在途。
        XCTAssertLessThanOrEqual(model.materializedCount, 30)
        XCTAssertLessThanOrEqual(host.reader.rowCache.count, LibraryScale.rowCacheCapacity)
    }

    func testCatalogChangesRequeryAfterDebounceAndRefreshChangedRows() async throws {
        let model = LibraryListModel(
            query: LibrarySongListQuery(.scope(.visible)),
            reader: host.reader,
            revisions: host.revisions,
            pageSize: 10,
            prefetchDistance: 10,
            debounce: .milliseconds(10)
        )
        model.activate()
        await waitUntil { !model.isLoading }
        XCTAssertEqual(model.count, 57)
        let firstGeneration = model.listGeneration
        let firstRow = await model.waitForItem(at: 0)
        var song = try XCTUnwrap(firstRow)

        // 加两首:成员变了,防抖后重查,行数跟着变。
        try write(LibraryCatalogMirrorTests.makeSongs(2, prefix: "added"))
        await host.mirror.waitUntilIdle()
        await waitUntil { model.count == 59 }
        XCTAssertEqual(model.count, 59)
        XCTAssertGreaterThan(model.listGeneration, firstGeneration)

        // 改第一首的标题:行缓存与窗口里的旧值都作废,重新物化拿到新标题。
        song.title = "Renamed first row"
        try write([song])
        await host.mirror.waitUntilIdle()
        await settleRevisions()
        var refreshed: Song?
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            refreshed = await model.waitForItem(at: 0)
            if refreshed?.title == "Renamed first row" { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(refreshed?.title, "Renamed first row")

        // 删一首:行号消失。
        try write([], deleting: [song.id])
        await host.mirror.waitUntilIdle()
        await waitUntil { model.count == 58 }
        XCTAssertEqual(model.count, 58)
    }

    func testAlbumAndArtistListsMaterializeByKey() async throws {
        let albums = host.albumList()
        let artists = host.artistList()
        albums.activate()
        artists.activate()
        await waitUntil { !albums.isLoading && !artists.isLoading }
        let albumKeys = try await host.reader.albumKeyList()
        XCTAssertEqual(albums.count, albumKeys.count)
        let firstAlbum = await albums.waitForItem(at: 0)
        let expectedAlbum = try await host.reader.albums(keys: [albumKeys.keys[0]]).first
        XCTAssertEqual(firstAlbum?.id, expectedAlbum?.id)
        let firstArtist = await artists.waitForItem(at: 0)
        XCTAssertNotNil(firstArtist)
    }
}
