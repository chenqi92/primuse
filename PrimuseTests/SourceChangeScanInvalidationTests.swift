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
        let source = MusicSource(id: "source", name: "NAS", type: .webdav, extraConfig: "[\"/Music\"]")
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

private final class ScanFixtureFileManager: FileManager, @unchecked Sendable {
    let root: URL
    init(root: URL) { self.root = root; super.init() }
    override func urls(for directory: FileManager.SearchPathDirectory,
                       in domainMask: FileManager.SearchPathDomainMask) -> [URL] { [root] }
}
