import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 改完目录后的深度重扫要活到收尾, 删除对账才做得成。iCloud 拉回来的那份
/// 一模一样的源记录以前会让 ScanService 把它半路取消, 被取消勾选的目录里的歌
/// 也就一直留在资料库里。
@MainActor
final class SourceChangeScanInvalidationTests: XCTestCase {
    func testUnchangedSourceRowKeepsRunningScanAndItsCheckpoint() async throws {
        let fixture = try makeFixture(pausedPaths: ["/Music"])
        XCTAssertTrue(fixture.start())
        try await fixture.waitUntilConnectorIsWaiting()
        let row = try XCTUnwrap(fixture.store.source(id: fixture.source.id))

        // 与本机行一字不差的记录从云端回来: 扫描与检查点都要留着。
        post(row, origin: "remote")
        try await settle()
        XCTAssertEqual(fixture.scan.scanStates[row.id]?.isScanning, true)
        // 取消后能续扫, 说明检查点没有被那条通知清掉。
        fixture.scan.cancelScan(for: row.id)
        XCTAssertEqual(fixture.scan.scanStates[row.id]?.canResume, true)
        await fixture.connector.release()
    }

    func testChangedDirectoryScopeStillCancelsRunningScan() async throws {
        let fixture = try makeFixture(pausedPaths: ["/Music"])
        XCTAssertTrue(fixture.start())
        try await fixture.waitUntilConnectorIsWaiting()
        var edited = try XCTUnwrap(fixture.store.source(id: fixture.source.id))
        edited.extraConfig = MusicSource.encodeScannedDirectories(
            ["/Other"], into: edited.extraConfig, type: edited.type
        )

        post(edited, origin: "remote")
        try await waitUntil { fixture.scan.scanStates[edited.id]?.isScanning != true }
        XCTAssertFalse(fixture.scan.hasResumableScanWork)
        await fixture.connector.release()
    }

    func testLocalEditStillCancelsRunningScan() async throws {
        let fixture = try makeFixture(pausedPaths: ["/Music"])
        XCTAssertTrue(fixture.start())
        try await fixture.waitUntilConnectorIsWaiting()

        // 本机编辑会改 modifiedAt, 哪怕目录没动也算作用域变了。
        fixture.store.update(fixture.source.id) { $0.name = "Renamed" }
        try await waitUntil { fixture.scan.scanStates[fixture.source.id]?.isScanning != true }
        XCTAssertFalse(fixture.scan.hasResumableScanWork)
        await fixture.connector.release()
    }

    func testUnchangedSourceRowKeepsCommittedFolderTopology() async throws {
        let fixture = try makeFixture(pausedPaths: [])
        XCTAssertTrue(fixture.start())
        try await waitUntil { fixture.store.source(id: fixture.source.id)?.lastScannedAt != nil }
        let row = try XCTUnwrap(fixture.store.source(id: fixture.source.id))
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: row.id).isEmpty)

        post(row, origin: "remote")
        try await settle()
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: row.id).isEmpty)

        var edited = row
        edited.extraConfig = MusicSource.encodeScannedDirectories(
            ["/Other"], into: edited.extraConfig, type: edited.type
        )
        post(edited, origin: "remote")
        try await settle()
        XCTAssertTrue(fixture.scan.libraryFolderSyncIndex(for: row.id).isEmpty)
    }

    func testRouteOnlyLocalEditKeepsFolderTopologyUnderTheNewScope() async throws {
        let fixture = try makeFixture(pausedPaths: [])
        XCTAssertTrue(fixture.start())
        try await waitUntil { fixture.store.source(id: fixture.source.id)?.lastScannedAt != nil }
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: fixture.source.id).isEmpty)

        // 给 NAS 换一个访问地址：内容没变，目录层级不能空到下次扫描。
        fixture.store.update(fixture.source.id) { $0.host = "nas.example.com" }
        try await settle()
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: fixture.source.id).isEmpty)

        // 同步状态已经换成新行的作用域：这一行从云端回来时不再被当成作用域变了。
        let edited = try XCTUnwrap(fixture.store.source(id: fixture.source.id))
        post(edited, origin: "remote")
        try await settle()
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: fixture.source.id).isEmpty)
    }

    func testLocalDirectoryEditStillDropsFolderTopology() async throws {
        let fixture = try makeFixture(pausedPaths: [])
        XCTAssertTrue(fixture.start())
        try await waitUntil { fixture.store.source(id: fixture.source.id)?.lastScannedAt != nil }
        XCTAssertFalse(fixture.scan.libraryFolderSyncIndex(for: fixture.source.id).isEmpty)

        fixture.store.update(fixture.source.id) {
            $0.extraConfig = MusicSource.encodeScannedDirectories(
                ["/Other"], into: $0.extraConfig, type: $0.type
            )
        }
        try await settle()
        XCTAssertTrue(fixture.scan.libraryFolderSyncIndex(for: fixture.source.id).isEmpty)
    }

    func testRemoteEchoOfLocalRowNeitherNotifiesNorRewritesIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceEcho-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = SourcesStore(storageDirectoryURL: root)
        store.add(MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]"))
        let stored = try XCTUnwrap(store.source(id: "source"))

        var notifications = 0
        let token = NotificationCenter.default.addObserver(
            forName: .primuseSourcesDidChange, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        // CloudKit 载荷去掉了设备本地字段; 拉回来时会用本地值补回, 结果与本地行相等。
        var echo = stored
        echo.lastScannedAt = nil
        echo.songCount = 0
        echo.deviceId = nil
        store.upsertFromRemote(echo)
        XCTAssertEqual(notifications, 0)
        XCTAssertEqual(store.source(id: "source"), stored)

        // 别的设备真改过的记录照常落地并广播。
        var edited = echo
        edited.name = "NAS on the Mac"
        edited.modifiedAt = stored.modifiedAt.addingTimeInterval(1)
        store.upsertFromRemote(edited)
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.source(id: "source")?.name, "NAS on the Mac")
    }

    // MARK: - Helpers

    private func post(_ source: MusicSource, origin: String) {
        NotificationCenter.default.post(
            name: .primuseSourcesDidChange,
            object: nil,
            userInfo: ["ids": [source.id], "sources": [source.id: source], "origin": origin]
        )
    }

    /// 给挂在主队列上的观察者一个运行的机会。
    private func settle() async throws {
        for _ in 0..<5 { try await Task.sleep(for: .milliseconds(20)) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private struct Fixture {
        let source: MusicSource
        let connector: PausableScanConnector
        let scan: ScanService
        let library: MusicLibrary
        let store: SourcesStore
        let manager: SourceManager

        @MainActor func start() -> Bool {
            scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store)
        }

        func waitUntilConnectorIsWaiting() async throws {
            let deadline = Date().addingTimeInterval(5)
            while await !connector.isWaiting, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let isWaiting = await connector.isWaiting
            XCTAssertTrue(isWaiting)
        }
    }

    private func makeFixture(pausedPaths: Set<String>) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceChangeScan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = MusicSource(
            id: "source", name: "NAS", type: .webdav, host: "192.168.0.50", extraConfig: "[\"/Music\"]"
        )
        let connector = PausableScanConnector(pausedPaths: pausedPaths)
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: ScanFixtureFileManager(root: root),
            connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in
                SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
            }
        )
        return Fixture(
            source: source, connector: connector, scan: scan, library: library, store: store,
            manager: SourceManager(sourcesProvider: { [] })
        )
    }
}

/// 一棵两层的目录树: 选中的根下有一个子目录, 扫完之后同步状态里才有目录行。
private actor PausableScanConnector: MusicSourceConnector {
    let sourceID = "source"
    let pausedPaths: Set<String>
    private(set) var isWaiting = false
    private var released = false

    init(pausedPaths: Set<String>) { self.pausedPaths = pausedPaths }
    func release() { released = true }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        if pausedPaths.contains(path) {
            isWaiting = true
            while !released { try await Task.sleep(for: .milliseconds(10)) }
        }
        guard path == "/Music" else { return [] }
        return [RemoteFileItem(name: "Sub", path: "/Music/Sub", isDirectory: true, size: 0, modifiedDate: nil)]
    }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }
}

/// #155：Navidrome 上删了文件、服务端扫过一次之后 `getScanStatus.lastScan` 就停住了。以前
/// 删除证词按它去重，之后每次完整走查都算同一份证词，提示「下一次扫描再次确认」却永远确认不了。
@MainActor
final class ServerCatalogDeletionScanTests: XCTestCase {
    func testLaterCompleteWalkUnderTheSameScanMarkerRemovesTheDeletedSong() async throws {
        let fixture = try makeFixture(songCount: 3)
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs(), ["song-000", "song-001", "song-002"])

        await fixture.connector.remove(["song-002"])
        try await fixture.scanOnce()
        // 一次走查只是一票证词。
        XCTAssertEqual(fixture.songIDs(), ["song-000", "song-001", "song-002"])

        // 服务端标记没变，但这是新的一次完整走查。
        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs(), ["song-000", "song-001"])
    }

    func testMassDisappearanceIsHeldThenRemovedByLaterCompleteWalks() async throws {
        let fixture = try makeFixture(songCount: 100)
        try await fixture.scanOnce()
        await fixture.connector.remove(Set((40..<100).map(Self.songID)))

        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs().count, 100)
        XCTAssertNotNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)

        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs().count, 100)
        XCTAssertNotNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)

        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs().count, 40)
        // 删完了，卡片上不能再挂「少了 0 首」。
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)
    }

    func testImmediateRemovalDeletesOnTheFirstCompleteWalk() async throws {
        let fixture = try makeFixture(songCount: 100)
        fixture.scan.serverCatalogRemovalModeHandler = { _ in .immediate }
        try await fixture.scanOnce()
        await fixture.connector.remove(Set((40..<100).map(Self.songID)))

        try await fixture.scanOnce()
        XCTAssertEqual(fixture.songIDs().count, 40)
        XCTAssertNil(fixture.scan.scanStates[fixture.source.id]?.reconciliationMessage)
    }

    private static func songID(_ index: Int) -> String {
        String(format: "song-%03d", index)
    }

    private struct Fixture {
        let source: MusicSource
        let connector: StillScanMarkerCatalogConnector
        let scan: ScanService
        let library: MusicLibrary
        let store: SourcesStore
        let manager: SourceManager

        @MainActor func scanOnce() async throws {
            XCTAssertTrue(scan.scanSource(source, sourceManager: manager, library: library, sourceStore: store))
            await scan.waitForActiveScansToComplete()
            await library.waitForPendingIndex()
            XCTAssertNil(scan.scanStates[source.id]?.failureMessage)
        }

        @MainActor func songIDs() -> [String] {
            library.songs.filter { $0.sourceID == source.id }.map(\.id).sorted()
        }
    }

    private func makeFixture(songCount: Int) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCatalogDeletion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let source = MusicSource(id: "navidrome", name: "Navidrome", type: .navidrome, host: "192.168.0.60")
        let connector = StillScanMarkerCatalogConnector(
            sourceID: source.id,
            songIDs: (0..<songCount).map(Self.songID)
        )
        let library = MusicLibrary(storageDirectory: root.appendingPathComponent("library"))
        let store = SourcesStore(storageDirectoryURL: root.appendingPathComponent("sources"))
        store.add(source)
        let scan = ScanService(
            fileManager: ScanFixtureFileManager(root: root),
            connectorProvider: { _ in connector },
            diagnosticProvider: { source, _ in
                SourceDiagnosticReport(source: source, startedAt: Date(), checks: [])
            }
        )
        // 收尾的歌单/收藏同步也走这个假连接器：它没有歌单能力，不会去连真的地址。
        return Fixture(
            source: source, connector: connector, scan: scan, library: library, store: store,
            manager: SourceManager(sourcesProvider: { [source] }, connectorFactory: { _ in connector })
        )
    }
}

/// Navidrome 式的 `search3` 分页目录。扫描标记照 `lastScan|count` 拼：删歌之后服务端扫过
/// 一次，数目变了一回，此后一直不动。
private actor StillScanMarkerCatalogConnector: ResumablePagedSongCatalogConnector {
    let sourceID: String
    private var songIDs: [String]

    init(sourceID: String, songIDs: [String]) {
        self.sourceID = sourceID
        self.songIDs = songIDs
    }

    func remove(_ removed: Set<String>) { songIDs.removeAll { removed.contains($0) } }
    func connect() async throws { }
    func disconnect() async { }
    func listFiles(at path: String) async throws -> [RemoteFileItem] { [] }
    func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        .init { $0.finish() }
    }
    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        .init { $0.finish() }
    }

    func stableSongCatalogRevision() async throws -> String? {
        "2026-10-01T08:00:00Z|\(songIDs.count)"
    }

    func expectedSongCatalogCount() async throws -> Int? { songIDs.count }

    func songCatalogPage(from path: String, offset: Int) async throws -> PagedSongCatalogPage {
        guard offset < songIDs.count else {
            return PagedSongCatalogPage(songs: [], itemIDs: [], nextOffset: nil)
        }
        let window = Array(songIDs[offset..<min(offset + SubsonicCatalogPagingPolicy.pageSize, songIDs.count)])
        let songs = window.map { id -> ConnectorScannedSong in
            let song = Song(id: id, title: "Song \(id)", fileFormat: .flac,
                            filePath: "/fixture/\(id).flac", sourceID: sourceID)
            return ConnectorScannedSong(song: song, displayName: song.title, titleMetadataInspected: true)
        }
        return PagedSongCatalogPage(
            songs: songs,
            itemIDs: window,
            nextOffset: SubsonicCatalogPagingPolicy.nextOffset(currentOffset: offset, receivedCount: window.count)
        )
    }
}

private final class ScanFixtureFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}
