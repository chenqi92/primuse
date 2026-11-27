import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 扫描的累积表改成与已有的歌共用一份数组(`ScanSongAccumulator`)之后,终态快照必须与原来逐项一样。
/// 文件走查的提交又改成只用「这一轮遇到的歌的 id + 改过的行」(不带整份快照):这里每跑一轮都核对,
/// 开始时的歌盖上走查交出来的改动行、走完时去掉没遇到的,和终态快照逐项相同;不带快照再跑一遍,
/// 遇到的 id、走没走完、改动的行也都一样。守住会让歌被误删或重复的几种情形:没变的照原样、删掉的文件去掉、
/// 改过的文件原地替换、新文件排在最后、有目录列不出来时一首都不删。改名的情形见 `SongFileRenameTests`,
/// 本机排除、墓碑、CUE 分轨的保留见 `DirectoryScanCooldownTests` 里的整轮扫描用例。
final class ConnectorScannerPruneTests: XCTestCase {
    private actor Tree {
        private var listings: [String: [RemoteFileItem]]
        private var failing: Set<String> = []
        private var missing: Set<String> = []
        private var contents: [String: Data] = [:]

        init(_ listings: [String: [RemoteFileItem]]) { self.listings = listings }

        func list(_ path: String) throws -> [RemoteFileItem] {
            if failing.contains(path) { throw HTTPResponseFailure(statusCode: 500) }
            if missing.contains(path) { throw SourceError.pathNotFound(path) }
            return listings[path] ?? []
        }

        func read(_ path: String) throws -> Data {
            guard let data = contents[path] else { throw SourceError.fileNotFound(path) }
            return data
        }

        func set(_ path: String, _ items: [RemoteFileItem]) { listings[path] = items }
        func fail(_ path: String) { failing.insert(path) }
        func remove(_ path: String) { missing.insert(path) }
        func write(_ path: String, _ data: Data) { contents[path] = data }
    }

    private struct TreeConnector: MusicSourceConnector {
        let tree: Tree
        let sourceID: String
        var mutationRoot: String?
        let directoryListingConcurrency = 1
        func connect() async throws {}
        func disconnect() async {}
        func listFiles(at path: String) async throws -> [RemoteFileItem] { try await tree.list(path) }
        func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data { try await tree.read(path) }
        func fileMutationRootPath() async throws -> String? { mutationRoot }
        func localURL(for path: String) async throws -> URL { throw SourceError.fileNotFound(path) }
        func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> { .init { $0.finish() } }
        func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> { .init { $0.finish() } }
    }

    private static func file(_ path: String, size: Int64 = 1_000, providerID: String? = nil) -> RemoteFileItem {
        RemoteFileItem(
            name: (path as NSString).lastPathComponent, path: path, isDirectory: false,
            size: size, modifiedDate: Date(timeIntervalSinceReferenceDate: 1_000), revision: "r\(size)",
            providerID: providerID
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

    /// 一轮走查交出来的东西。
    private struct Walk {
        var snapshot: [Song] = []
        var carriedSnapshot = false
        /// 走查记下的改动行,按先后(`takePendingChangedSongs`)。
        var changes: [Song] = []
        var outcome: ConnectorScanner.FileWalkOutcome?
        var encountered: Set<String> = []
        var terminalScannedCount = 0
        var index = SourceSyncIndex()
        var failed = false
    }

    private func walk(
        _ tree: Tree, sourceID: String, existing: [Song], identityIndex: SourceSyncIndex,
        mutationRoot: String?, carriesSnapshot: Bool
    ) async -> Walk {
        let scanner = ConnectorScanner(
            connector: TreeConnector(tree: tree, sourceID: sourceID, mutationRoot: mutationRoot), sourceID: sourceID
        )
        var result = Walk()
        do {
            for try await update in await scanner.scan(
                directories: ["/"], existingSongs: existing, identityIndex: identityIndex,
                fileWalkCarriesSnapshot: carriesSnapshot
            ) {
                result.changes.append(contentsOf: await scanner.takePendingChangedSongs())
                if update.carriesFullSnapshot {
                    result.snapshot = update.songs
                    result.carriedSnapshot = true
                } else {
                    XCTAssertTrue(update.songs.isEmpty)
                }
                if let outcome = update.fileWalkOutcome {
                    result.outcome = outcome
                    result.encountered = update.resumeState?.walkLog.songIDSet() ?? []
                    result.terminalScannedCount = update.scannedCount
                }
            }
        } catch {
            result.failed = true
        }
        result.changes.append(contentsOf: await scanner.takePendingChangedSongs())
        result.index = await scanner.syncIndexSnapshot()
        return result
    }

    /// 新歌的加入时间是走查那一刻,两轮走查之间不同;别的字段都要一样。
    private static func rowsByID(_ songs: [Song], ignoringDateAdded: Bool = false) -> [String: Song] {
        var rows: [String: Song] = [:]
        for var song in songs {
            if ignoringDateAdded { song.dateAdded = .distantPast }
            rows[song.id] = song
        }
        return rows
    }

    /// 跑一轮扫描,返回终态快照与有没有报错。同时按文件走查的提交口径核对一遍(见类型说明)。
    private func scan(
        _ tree: Tree, sourceID: String, existing: [Song] = [], identityIndex: SourceSyncIndex = SourceSyncIndex(),
        mutationRoot: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) async -> (songs: [Song], failed: Bool, index: SourceSyncIndex, changes: [Song]) {
        let full = await walk(
            tree, sourceID: sourceID, existing: existing, identityIndex: identityIndex,
            mutationRoot: mutationRoot, carriesSnapshot: true
        )
        if let outcome = full.outcome {
            // 提交拿到的:开始时的歌(同一个 id 取第一份)盖上改动行(同一个 id 取最后一份),走完了才去掉没遇到的。
            var rebuilt: [String: Song] = [:]
            for song in existing where rebuilt[song.id] == nil { rebuilt[song.id] = song }
            for song in full.changes { rebuilt[song.id] = song }
            if outcome == .complete { rebuilt = rebuilt.filter { full.encountered.contains($0.key) } }
            XCTAssertEqual(rebuilt, Self.rowsByID(full.snapshot), "changes + encountered must rebuild the terminal snapshot",
                           file: file, line: line)
            XCTAssertEqual(outcome == .incomplete, full.failed, file: file, line: line)

            let bare = await walk(
                tree, sourceID: sourceID, existing: existing, identityIndex: identityIndex,
                mutationRoot: mutationRoot, carriesSnapshot: false
            )
            XCTAssertFalse(bare.carriedSnapshot, "a file walk asked not to carry snapshots must not build one", file: file, line: line)
            XCTAssertEqual(bare.outcome, outcome, file: file, line: line)
            XCTAssertEqual(bare.failed, full.failed, file: file, line: line)
            XCTAssertEqual(bare.encountered, full.encountered, file: file, line: line)
            XCTAssertEqual(bare.terminalScannedCount, full.terminalScannedCount, file: file, line: line)
            XCTAssertEqual(
                Self.rowsByID(bare.changes, ignoringDateAdded: true), Self.rowsByID(full.changes, ignoringDateAdded: true),
                file: file, line: line
            )
            XCTAssertEqual(bare.changes.map(\.id), full.changes.map(\.id), file: file, line: line)
        }
        return (full.snapshot, full.failed, full.index, full.changes)
    }

    func testUnchangedRescanKeepsEverySongInOrder() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        XCTAssertFalse(initial.failed)
        XCTAssertEqual(Set(initial.songs.map(\.filePath)), ["/a.flac", "/b.flac", "/sub/c.flac", "/sub/d.flac"])
        XCTAssertEqual(initial.changes.count, 4, "every new row is handed over as a change")
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(rescan.songs.map(\.id), initial.songs.map(\.id))
        XCTAssertEqual(rescan.songs.map(\.fileSize), initial.songs.map(\.fileSize))
        XCTAssertTrue(rescan.changes.isEmpty, "an unchanged walk hands over no rows")
    }

    func testRemovedFileIsDroppedAndTheRestKeepTheirOrder() async throws {
        let tree = makeTree()
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        await tree.set("/", [Self.file("/a.flac"), Self.directory("/sub")])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(rescan.songs.map(\.id), initial.songs.filter { $0.filePath != "/b.flac" }.map(\.id))
        XCTAssertTrue(rescan.changes.isEmpty, "a removal is told by the encountered ids alone")
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
        XCTAssertEqual(rescan.changes.map(\.filePath), ["/b.flac"])
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
        XCTAssertEqual(rescan.changes.map(\.filePath), ["/sub/e.flac"])
    }

    /// 按提供方 id 认条目的文件挪了地方:还是那首歌,换了路径的行作为改动交出来,旧路径不算删。
    func testMovedFileKeepsItsSongAndIsHandedOverAsAChange() async throws {
        let tree = Tree([
            "/": [Self.file("/a.flac", providerID: "id-a"), Self.directory("/sub")],
            "/sub": [Self.file("/sub/c.flac", providerID: "id-c")],
        ])
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        let moved = try XCTUnwrap(initial.songs.first { $0.filePath == "/a.flac" })
        await tree.set("/", [Self.directory("/sub")])
        await tree.set("/sub", [Self.file("/sub/c.flac", providerID: "id-c"), Self.file("/sub/a.flac", providerID: "id-a")])
        let rescan = await scan(tree, sourceID: sourceID, existing: initial.songs, identityIndex: initial.index)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(Set(rescan.songs.map(\.id)), Set(initial.songs.map(\.id)))
        XCTAssertEqual(rescan.songs.first { $0.id == moved.id }?.filePath, "/sub/a.flac")
        XCTAssertEqual(rescan.changes.map(\.id), [moved.id])
    }

    /// CUE 分轨里有本机隐藏的(走查拿它们当已有的歌):镜像没变时一行都不交,镜像没了才都不再遇到。
    func testCueTracksIncludingHiddenOnesAreEncounteredWithoutChanges() async throws {
        let cue = Data("""
        FILE "image.flac" WAVE
          TRACK 01 AUDIO
            TITLE "First Light"
            INDEX 01 00:00:00
          TRACK 02 AUDIO
            TITLE "Evening Walk"
            INDEX 01 03:00:00
        """.utf8)
        let tree = Tree([
            "/": [Self.file("/a.flac"), Self.file("/image.flac", size: 50_000), Self.file("/image.cue", size: Int64(cue.count))],
        ])
        await tree.write("/image.cue", cue)
        let sourceID = "prune-\(UUID().uuidString)"
        let initial = await scan(tree, sourceID: sourceID)
        XCTAssertFalse(initial.failed)
        let tracks = initial.songs.filter(\.isCueTrack)
        XCTAssertEqual(tracks.count, 2)
        // 资料库里只剩一条分轨、另一条是本机隐藏的:两条都作为已有的歌交给走查,顺序是库里的在前。
        let existing = initial.songs.filter { $0.id != tracks[1].id } + [tracks[1]]
        let rescan = await scan(tree, sourceID: sourceID, existing: existing, identityIndex: initial.index)
        XCTAssertFalse(rescan.failed)
        XCTAssertEqual(Set(rescan.songs.map(\.id)), Set(initial.songs.map(\.id)))
        XCTAssertTrue(rescan.changes.isEmpty)

        await tree.set("/", [Self.file("/a.flac")])
        let removed = await scan(tree, sourceID: sourceID, existing: existing, identityIndex: initial.index)
        XCTAssertFalse(removed.failed)
        XCTAssertEqual(removed.songs.map(\.filePath), ["/a.flac"])
        XCTAssertTrue(removed.changes.isEmpty)
    }

    /// 旧版本把挪进根目录的歌只存了文件名:走查开始前修成完整路径。修过的行即使这一轮没有别的改动可记
    /// (它在一个列不出来、当作缺失的子目录里,只是被保住),也要作为改动交出来 —— 原来靠整份终态快照带进库。
    func testRootRepairedRowKeptUnderAMissingChildIsHandedOverAsAChange() async throws {
        let tree = Tree(["/": [Self.file("/a.flac"), Self.directory("/home")]])
        await tree.remove("/home")
        let sourceID = "prune-\(UUID().uuidString)"
        let legacy = Song(id: "legacy-row", title: "Moved", fileFormat: .flac, filePath: "moved.flac", sourceID: sourceID)
        let result = await scan(tree, sourceID: sourceID, existing: [legacy], mutationRoot: "/home")
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.songs.first { $0.id == legacy.id }?.filePath, "/home/moved.flac")
        XCTAssertEqual(result.changes.first { $0.id == legacy.id }?.filePath, "/home/moved.flac")
    }
}
