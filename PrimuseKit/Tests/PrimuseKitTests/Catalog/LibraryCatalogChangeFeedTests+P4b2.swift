import Foundation
import GRDB
import Testing
@testable import PrimuseKit

/// 目录变更流水上的位置:导入做完才有;之后的增、改、删按先后给出去重的 id;重新导入、换文件后旧位置作废。
@Suite("Library catalog change feed", .serialized)
struct LibraryCatalogChangeFeedTests {
    static func song(_ id: String, title: String = "t") -> Song {
        Song(id: id, title: title, duration: 100, fileFormat: .flac, filePath: "Music/\(id).flac", sourceID: "src")
    }

    static func markImported(_ catalog: LibraryCatalog, revision: String = "7", count: String = "3") throws {
        try catalog.pool.write { db in
            try LibraryCatalog.setMeta(LibraryCatalog.MetaKey.importState, "complete", in: db)
            try LibraryCatalog.setMeta(LibraryCatalog.MetaKey.importStoreRevision, revision, in: db)
            try LibraryCatalog.setMeta(LibraryCatalog.MetaKey.importedCount, count, in: db)
        }
    }

    @Test("Changes after a cursor come back once each, in order, with deletions and renames")
    func changesSinceCursor() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: [Self.song("a"), Self.song("b"), Self.song("c")])
        #expect(try catalog.changeCursor() == nil)
        try Self.markImported(catalog)
        let start = try #require(try catalog.changeCursor())

        try catalog.apply(upserts: [Self.song("b", title: "changed"), Self.song("d")])
        try catalog.apply(upserts: [], deletingIDs: ["a"])
        try catalog.apply(upserts: [Self.song("b", title: "again")])
        try catalog.apply(upserts: [], renaming: ["c": "c2"])

        let batch = try #require(try catalog.changedSongIDs(since: start, limit: 100))
        #expect(batch.songIDs == ["b", "d", "a", "c2"])
        #expect(!batch.isTruncated)
        #expect(batch.cursor.epoch == start.epoch)
        #expect(batch.cursor == (try catalog.changeCursor()))
        let empty = try #require(try catalog.changedSongIDs(since: batch.cursor, limit: 100))
        #expect(empty.songIDs.isEmpty)
        #expect(empty.cursor == batch.cursor)

        let limited = try #require(try catalog.changedSongIDs(since: start, limit: 2))
        #expect(limited.songIDs == ["b", "d"])
        #expect(limited.isTruncated)
        let rest = try #require(try catalog.changedSongIDs(since: limited.cursor, limit: 100))
        #expect(rest.songIDs == ["a", "b", "c2"])
    }

    @Test("A new import or a cursor from another feed is not trusted")
    func staleCursors() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: [Self.song("a")])
        try Self.markImported(catalog)
        let cursor = try #require(try catalog.changeCursor())
        try catalog.apply(upserts: [Self.song("b")])

        #expect(try catalog.changedSongIDs(since: LibraryCatalogChangeCursor(epoch: "other", seq: cursor.seq), limit: 10) == nil)
        #expect(try catalog.changedSongIDs(since: LibraryCatalogChangeCursor(epoch: cursor.epoch, seq: cursor.seq + 1_000), limit: 10) == nil)

        try Self.markImported(catalog, revision: "8")
        #expect(try catalog.changedSongIDs(since: cursor, limit: 10) == nil)

        try catalog.pool.write { db in
            try LibraryCatalog.setMeta(LibraryCatalog.MetaKey.importState, "running", in: db)
        }
        #expect(try catalog.changeCursor() == nil)

        let other = try TemporaryCatalog()
        try other.catalog.apply(upserts: [Self.song("a")])
        try Self.markImported(other.catalog)
        let otherCursor = try #require(try other.catalog.changeCursor())
        #expect(otherCursor.epoch != cursor.epoch)
    }

    @Test("The feed keeps only the newest entries, and a cursor behind the trimmed part cannot catch up")
    func trimmedFeed() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: [Self.song("a"), Self.song("b")])
        try Self.markImported(catalog)
        let start = try #require(try catalog.changeCursor())
        // 造出超过上限的流水(直接写表,不必真的改五万首歌)。
        let extra = LibraryCatalog.changeFeedLimit + 10
        try catalog.pool.write { db in
            let insert = try db.makeStatement(sql: "INSERT INTO catalogChange (kind, songRowid, songID) VALUES (1, 1, ?)")
            for index in 0..<extra { try insert.execute(arguments: ["filler-\(index)"]) }
            try LibraryCatalog.trimChangeFeed(in: db)
        }
        let remaining = try catalog.pool.read { db in try Int64.fetchOne(db, sql: "SELECT count(*) FROM catalogChange") }
        #expect(remaining == LibraryCatalog.changeFeedLimit)
        #expect(try catalog.changedSongIDs(since: start, limit: 100) == nil)
        let fresh = try #require(try catalog.changeCursor())
        try catalog.apply(upserts: [Self.song("a", title: "after trim")])
        let batch = try #require(try catalog.changedSongIDs(since: fresh, limit: 100))
        #expect(batch.songIDs == ["a"])
    }
}
