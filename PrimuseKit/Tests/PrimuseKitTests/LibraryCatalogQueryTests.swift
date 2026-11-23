import Foundation
import GRDB
import Testing
@testable import PrimuseKit

@Suite("Library catalog queries and import", .serialized)
struct LibraryCatalogQueryTests {
    static func song(_ id: String, source: String, path: String, title: String = "t", duration: Double = 100) -> Song {
        Song(id: id, title: title, duration: duration, fileFormat: .flac, filePath: path, sourceID: source)
    }

    @Test("Source, path and count queries")
    func sourceAndPathQueries() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = [
            Self.song("a1", source: "A", path: "Music/X/01.flac"),
            Self.song("a2", source: "A", path: "Music/X/02.flac"),
            Self.song("a3", source: "A", path: "Music/X/Sub/03.flac"),
            Self.song("a4", source: "A", path: "Music/Y/04.flac"),
            Self.song("a5", source: "A", path: "Music/X0/05.flac"),
            Self.song("cue1", source: "A", path: "Music/X/album.ape"),
            Self.song("cue2", source: "A", path: "Music/X/album.ape"),
            Self.song("b1", source: "B", path: "", duration: 0),
            Self.song("b2", source: "B", path: "Music/X/01.flac"),
        ]
        try catalog.apply(upserts: songs)
        func ids(_ list: LibraryRowList) throws -> [String] { try catalog.songs(rowids: list.rowids).map(\.id) }

        #expect(try catalog.songCount(.everything) == 9)
        #expect(try catalog.songCountsBySource() == ["A": 7, "B": 2])
        #expect(try catalog.songCount(LibrarySongScope(playableOnly: true)) == 8)
        #expect(try ids(catalog.rowList(.source("A"))) == ["a1", "a2", "a3", "a4", "a5", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", directory: "Music/X", recursive: false)) == ["a1", "a2", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", directory: "Music/X", recursive: true)) == ["a1", "a2", "a3", "cue1", "cue2"])
        #expect(try ids(catalog.rowList(sourceID: "A", filePath: "Music/X/album.ape")) == ["cue1", "cue2"])
        #expect(try catalog.fileStems(sourceID: "A", directory: "Music/X") == ["01", "02", "album"])
        #expect(try catalog.songID(sourceID: "B", filePath: "Music/X/01.flac") == "b2")
        #expect(try catalog.firstSong(.source("B"))?.id == "b1")
        #expect(try catalog.containsSongs(.source("C")) == false)

        try catalog.setSourceEnabled(false, sourceID: "B")
        #expect(try catalog.songCount(.visible) == 7)
        #expect(try catalog.songCount(.everything) == 9)
        #expect(try catalog.songs(ids: ["b1", "a1"], scope: .visible).map(\.id) == ["a1"])
        #expect(try catalog.songs(ids: ["b1", "a1"]).map(\.id) == ["b1", "a1"])

        var streamed: [String] = []
        try catalog.forEachSongIdentity(.source("A")) { _, id, _ in
            streamed.append(id)
            return streamed.count < 3
        }
        #expect(streamed == ["a1", "a2", "a3"])
        var all: [String] = []
        try catalog.forEachSong(.everything) { _, song in
            all.append(song.id)
            return true
        }
        #expect(all == songs.map(\.id))
    }

    @Test("Prefix upper bounds cover exactly the strings that start with the prefix")
    func prefixBounds() {
        #expect(LibraryCatalogPath.upperBound(forPrefix: "a/b/") == "a/b0")
        #expect(LibraryCatalogPath.upperBound(forPrefix: "晴") > "晴天")
        #expect(LibraryCatalogPath.upperBound(forPrefix: "x\u{10FFFF}") == "y")
    }

    @Test("Row cache materializes in batches, keeps order and evicts least recently used")
    func rowCache() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let songs = (0..<20).map { Self.song("s\($0)", source: "A", path: "p/\($0).flac") }
        let summary = try catalog.apply(upserts: songs)
        let rowids = Array(summary.insertedRowids)
        let cache = LibraryRowCache(capacity: 8)
        let firstPage = try cache.songs(forRowids: rowids[0..<8], in: catalog)
        #expect(firstPage.map { $0?.id } == (0..<8).map { "s\($0)" })
        #expect(cache.count == 8)
        _ = try cache.songs(forRowids: [rowids[0]], in: catalog)
        _ = try cache.songs(forRowids: rowids[8..<10], in: catalog)
        #expect(cache.count == 8)
        // s0 刚用过;s1、s2 最久没用,被挤掉。
        let reversed = try cache.songs(forRowids: [rowids[9], rowids[0], rowids[1]], in: catalog)
        #expect(reversed.map { $0?.id } == ["s9", "s0", "s1"])
        let deleted = try catalog.apply(upserts: [], deletingIDs: ["s0"])
        cache.invalidate(deleted)
        #expect(try cache.songs(forRowids: [rowids[0]], in: catalog) == [nil])
    }

    /// 合成一个 `library-songs.sqlite`。
    static func makeStore(at path: String, songs: [Song]) throws -> IncrementalSongStore {
        let store = try IncrementalSongStore(path: path)
        try store.replaceAll(with: songs)
        return store
    }

    @Test("Import streams the incremental store, resumes after interruption, and matches a one-shot import")
    func resumableImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 77)
        let songs = (0..<1_234).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let store = try Self.makeStore(at: storePath, songs: songs)
        // 再追加几首:新行的 orderKey 排在后面。
        let extra = (0..<5).map { CatalogSongFactory.randomSong(&rng, index: 5_000 + $0, exotic: false).withoutAppliedPlaybackRange }
        try store.apply(upserts: extra)
        let expectedOrder = try store.loadSongs()

        let resumedPath = directory.appendingPathComponent("resumed.sqlite").path
        do {
            let catalog = try LibraryCatalog(path: resumedPath)
            let partial = try LibraryCatalogImporter.importIncrementalSongStore(
                at: storePath, into: catalog, batchSize: 100, maximumBatches: 3
            )
            #expect(partial.isComplete == false)
            #expect(partial.imported == 300)
        }
        let resumedCatalog = try LibraryCatalog(path: resumedPath)
        var reports: [LibraryCatalogImportProgress] = []
        let finished = try LibraryCatalogImporter.importIncrementalSongStore(
            at: storePath, into: resumedCatalog, batchSize: 100, progress: { reports.append($0) }
        )
        #expect(finished.isComplete)
        #expect(finished.imported == expectedOrder.count)
        #expect(reports.first?.imported == 400)

        let oneShot = try LibraryCatalog(path: directory.appendingPathComponent("oneshot.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: oneShot)

        func indexNames(_ catalog: LibraryCatalog) throws -> Set<String> {
            try catalog.pool.read { db in
                try Set(String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'index'"))
            }
        }
        for catalog in [resumedCatalog, oneShot] {
            var imported: [Song] = []
            try catalog.forEachSong(.everything) { _, song in
                imported.append(song)
                return true
            }
            #expect(imported == expectedOrder)
            // 迁移只建必需的索引;本地化排序索引记成待建,打开时也不建。
            #expect(try indexNames(catalog).isSuperset(of: LibraryCatalogSchema.migrationIndexes.map(\.name)))
            #expect(try indexNames(catalog).isDisjoint(with: LibraryCatalogSchema.backgroundSortIndexNames))
            #expect(try catalog.hasPendingSortIndexes())
        }
        let reopened = try LibraryCatalog(path: resumedPath)
        #expect(try indexNames(reopened).isDisjoint(with: LibraryCatalogSchema.backgroundSortIndexNames))
        #expect(try reopened.hasPendingSortIndexes())
        // 索引没建好时这几种排序整表排;建好后走索引,结果一样。
        let orders: [LibrarySongSortOrder] = [.artist, .artistDescending, .album, .albumDescending, .fileName, .fileNameDescending]
        let pendingLists = try orders.map { try reopened.songRowList(order: $0).rowids }
        var asked = 0
        #expect(try reopened.buildPendingSortIndexes(isCancelled: { asked += 1; return asked > 1 }) == false)
        #expect(try reopened.hasPendingSortIndexes())
        #expect(try reopened.buildPendingSortIndexes())
        #expect(try orders.map { try reopened.songRowList(order: $0).rowids } == pendingLists)
        #expect(try indexNames(reopened).isSuperset(of: LibraryCatalogSchema.deferredIndexes.map(\.name)))
        #expect(try !reopened.hasPendingSortIndexes())
        // 已完成:再调一次什么也不做。
        let again = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: oneShot)
        #expect(again.isComplete)
        #expect(try oneShot.songCount(.everything) == expectedOrder.count)
    }

    @Test("Source traits changed mid-import apply from the next written batch, as in a sequential import")
    func importRechecksSourceTraits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 79)
        let songs = (0..<600).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        _ = try Self.makeStore(at: storePath, songs: songs)
        // 改特征要有可见效果:选一个按路径取文件名的源(Apple Music 本来就用标题)。
        let target = try #require(songs.first {
            $0.sourceID != AppleMusicLibraryIdentity.sourceID && !$0.filePath.isEmpty
        }).sourceID
        func flip(_ catalog: LibraryCatalog) throws {
            try catalog.pool.write { db in
                try db.execute(sql: "UPDATE source SET fileNamesFromIndex = 1 WHERE id = ?", arguments: [target])
            }
        }
        func songRows(_ catalog: LibraryCatalog) throws -> [[DatabaseValue]] {
            try catalog.pool.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM song ORDER BY rowid").map { Array($0.databaseValues) }
            }
        }

        // 下一批在写第一批时已按旧特征算好;第一批写完后改特征,写下一批前要发现并重算。
        let pipelined = try LibraryCatalog(path: directory.appendingPathComponent("pipelined.sqlite").path)
        var flipped = false
        _ = try LibraryCatalogImporter.importIncrementalSongStore(
            at: storePath, into: pipelined, batchSize: 100,
            progress: { _ in
                guard !flipped else { return }
                flipped = true
                usleep(200_000)
                try? flip(pipelined)
            }
        )
        // 参照:逐批导入时,第一批之后改特征,后面的批次按新特征写。
        let reference = try LibraryCatalog(path: directory.appendingPathComponent("reference.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: reference, batchSize: 100, maximumBatches: 1)
        try flip(reference)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: reference, batchSize: 100)
        let unchanged = try LibraryCatalog(path: directory.appendingPathComponent("unchanged.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: unchanged, batchSize: 100)

        #expect(flipped)
        #expect(try songRows(pipelined) == songRows(reference))
        #expect(try songRows(pipelined) != songRows(unchanged))
    }

    @Test("Renaming song IDs keeps rowids and library order; the result equals a fresh catalog of the same songs")
    func renamingKeepsRowsInPlace() throws {
        var rng = CatalogTestRandom(seed: 80)
        let songs = (0..<40).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        _ = try catalog.apply(upserts: songs)
        let before = try catalog.rowList(.everything).rowids
        let rowid0 = try #require(try catalog.rowids(forIDs: [songs[0].id]).first ?? nil)
        let rowid5 = try #require(try catalog.rowids(forIDs: [songs[5].id]).first ?? nil)

        // 改标签换了身份:带着新值改名;只改名不带新值;新 id 已被占(退回删旧行、写到已有那行)。
        var renamed0 = songs[0]
        renamed0.id = songs[0].id + "-v2"
        renamed0.title = "Edited"
        var merged7 = songs[7]
        merged7.id = songs[8].id
        _ = try catalog.apply(
            upserts: [renamed0, merged7],
            deletingIDs: [songs[0].id, songs[7].id],
            renaming: [songs[0].id: renamed0.id, songs[5].id: songs[5].id + "-v2", songs[7].id: songs[8].id]
        )
        #expect(try catalog.song(id: songs[0].id) == nil)
        #expect(try catalog.song(id: songs[7].id) == nil)
        #expect(try catalog.rowids(forIDs: [renamed0.id]) == [rowid0])
        #expect(try catalog.rowids(forIDs: [songs[5].id + "-v2"]) == [rowid5])
        #expect(try catalog.song(id: renamed0.id)?.title == "Edited")
        #expect(try catalog.rowList(.everything).rowids.count == before.count - 1)

        // 与一个按同样顺序写入同样最终歌曲的新目录逐项相同。
        var final = songs
        final[0] = renamed0
        final[5].id = songs[5].id + "-v2"
        final[8] = merged7
        final.remove(at: 7)
        let fresh = try TemporaryCatalog()
        _ = try fresh.catalog.apply(upserts: final)
        func ids(_ catalog: LibraryCatalog) throws -> [String] {
            var result: [String] = []
            try catalog.forEachSong(.everything) { _, song in
                result.append(song.id)
                return true
            }
            return result
        }
        func albums(_ catalog: LibraryCatalog) throws -> [String] {
            try catalog.albums(keys: catalog.albumKeys(visibleOnly: false).keys, visibleCounts: false)
                .map { "\($0.id)|\($0.title)|\($0.songCount)" }.sorted()
        }
        #expect(try ids(catalog) == ids(fresh.catalog))
        #expect(try albums(catalog) == albums(fresh.catalog))
        #expect(try catalog.songCountsBySource(.everything) == fresh.catalog.songCountsBySource(.everything))
    }

    @Test("A store that changed between runs restarts the import")
    func importRestartsWhenStoreChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var rng = CatalogTestRandom(seed: 78)
        let songs = (0..<300).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false).withoutAppliedPlaybackRange }
        let storePath = directory.appendingPathComponent("library-songs.sqlite").path
        let store = try Self.makeStore(at: storePath, songs: songs)
        let catalog = try LibraryCatalog(path: directory.appendingPathComponent("c.sqlite").path)
        _ = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog, batchSize: 50, maximumBatches: 2)
        var edited = songs[0]
        edited.title = "changed in between"
        try store.apply(upserts: [edited], deletingIDs: [songs[299].id])
        let result = try LibraryCatalogImporter.importIncrementalSongStore(at: storePath, into: catalog, batchSize: 50)
        #expect(result.isComplete)
        #expect(try catalog.songCount(.everything) == 299)
        #expect(try catalog.song(id: songs[0].id)?.title == "changed in between")
    }
}
