import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 扫描的累积表改成与已有的歌共用一份数组(`ScanSongAccumulator`)之后,终态快照必须与原来逐项一样:
/// `completeScan` 拿它做删除对账。这里守住会让歌被误删或重复的几种情形:没变的照原样、删掉的文件去掉、
/// 改过的文件原地替换、新文件排在最后、有目录列不出来时一首都不删。改名的情形见 `SongFileRenameTests`,
/// 本机排除、墓碑、CUE 分轨的保留见 `DirectoryScanCooldownTests` 里的整轮扫描用例。
final class ConnectorScannerPruneTests: XCTestCase {
    private actor Tree {
        private var listings: [String: [RemoteFileItem]]
        private var failing: Set<String> = []

        init(_ listings: [String: [RemoteFileItem]]) { self.listings = listings }

        func list(_ path: String) throws -> [RemoteFileItem] {
            if failing.contains(path) { throw HTTPResponseFailure(statusCode: 500) }
            return listings[path] ?? []
        }

        func set(_ path: String, _ items: [RemoteFileItem]) { listings[path] = items }
        func fail(_ path: String) { failing.insert(path) }
    }

    private struct TreeConnector: MusicSourceConnector {
        let tree: Tree
        let sourceID: String
        let directoryListingConcurrency = 1
        func connect() async throws {}
        func disconnect() async {}
        func listFiles(at path: String) async throws -> [RemoteFileItem] { try await tree.list(path) }
        func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
        func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
        func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    }

    private static func file(_ path: String, size: Int64 = 1_000) -> RemoteFileItem {
        RemoteFileItem(
            name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
            size: size, modifiedDate: Date(timeIntervalSinceReferenceDate: 1_000), revision: "r\(size)"
        )
    }

    private static func directory(_ path: String) -> RemoteFileItem {
        RemoteFileItem(name: (path as NSString).lastPathComponent, path: path, isDirectory: true, size: 0, modifiedDate: nil)
    }

    private func makeTree() -> Tree {
        Tree([
            "/": [Self.file("/a.flac"), Self.file("/b.flac"), Self.directory("/sub")],
            "/sub": [Self.file("/sub/c.flac"), Self.file("/sub/d.flac")],
        ])
    }

    /// 跑一轮扫描,返回终态快照与有没有报错。
    private func scan(_ tree: Tree, sourceID: String, existing: [Song] = []) async -> (songs: [Song], failed: Bool) {
        let scanner = ConnectorScanner(connector: TreeConnector(tree: tree, sourceID: sourceID), sourceID: sourceID)
        var snapshot: [Song] = []
        var failed = false
        do {
            for try await update in await scanner.scan(directories: ["/"], existingSongs: existing) where update.carriesFullSnapshot {
                snapshot = update.songs
            }
        } catch {
            failed = true
        }
        return (snapshot, failed)
    }

    func testUnchangedRescanKeepsEverySongInOrder() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        XCTAssertFalse(initial.failed)
        XCTAssertEqual(Set(initial.songs.map(\.filePath)), ["/a.flac", "/b.flac", "/sub/c.flac", "/sub/d.flac"])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(rescan.songs.map(\.id), initial.songs.map(\.id))
        XCTAssertEqual(rescan.songs.map(\.fileSize), initial.songs.map(\.fileSize))
    }

    func testRemovedFileIsDroppedAndTheRestKeepTheirOrder() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        await tree.set("/", [Self.file("/a.flac"), Self.directory("/sub")])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(rescan.songs.map(\.id), initial.songs.filter { $0.filePath != "/b.flac" }.map(\.id))
    }

    func testFailedDirectoryKeepsEveryExistingSong() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        // 一个目录列不出来:别的目录里少了的歌这一轮也不能删(读不全不算远端少了)。
        await tree.set("/", [Self.file("/b.flac"), Self.directory("/sub")])
        await tree.fail("/sub")
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertTrue(rescan.failed)
        XCTAssertEqual(Set(rescan.songs.map(\.id)), Set(initial.songs.map(\.id)))
    }

    func testChangedFileIsReplacedInPlace() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        await tree.set("/", [Self.file("/a.flac"), Self.file("/b.flac", size: 2_000), Self.directory("/sub")])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(rescan.songs.map(\.id), initial.songs.map(\.id))
        XCTAssertEqual(rescan.songs.first { $0.filePath == "/b.flac" }?.fileSize, 2_000)
        XCTAssertEqual(
            rescan.songs.first { $0.filePath == "/b.flac" }?.dateAdded,
            initial.songs.first { $0.filePath == "/b.flac" }?.dateAdded
        )
    }

    func testNewFileComesAfterTheExistingSongs() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        await tree.set("/sub", [Self.file("/sub/c.flac"), Self.file("/sub/d.flac"), Self.file("/sub/e.flac")])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(Array(rescan.songs.prefix(initial.songs.count)).map(\.id), initial.songs.map(\.id))
        XCTAssertEqual(rescan.songs.last?.filePath, "/sub/e.flac")
        XCTAssertEqual(rescan.songs.count, initial.songs.count + 1)
    }
}
