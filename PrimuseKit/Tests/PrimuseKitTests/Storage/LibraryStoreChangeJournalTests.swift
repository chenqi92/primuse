import Foundation
import GRDB
import Testing
@testable import PrimuseKit

/// 旧库的变更流水:`IncrementalSongStore.apply` 在同一个事务里记下每个修订号做了什么,落在后面的曲库目录
/// 据此只补改过的行(`IncrementalSongStoreScanner.replayChanges`),结果与一直跟着写的目录相同。
@Suite("Song store change journal", .serialized)
struct LibraryStoreChangeJournalTests {
    static func song(_ id: String, title: String = "t") -> Song {
        var song = Song(id: id, title: title, duration: 100, fileFormat: .flac, filePath: "Music/\(id).flac", sourceID: "src")
        song.dateAdded = Date(timeIntervalSince1970: 1_700_000_000)
        return song
    }

    /// 临时目录里的一个旧库。
    final class TemporaryStore {
        let directory: URL
        let path: String
        let store: IncrementalSongStore

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("store-journal-tests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            path = directory.appendingPathComponent("library-songs.sqlite").path
            store = try IncrementalSongStore(path: path)
        }

        func scanner() throws -> IncrementalSongStoreScanner { try IncrementalSongStoreScanner(path: path) }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    /// 重放 `revision` 之后的流水,收下各批。
    static func replay(
        _ store: TemporaryStore, after revision: Int64, maximumRows: Int = 10_000, maximumRowsPerRevision: Int = 10_000
    ) throws -> (outcome: IncrementalSongStoreChangeReplay, batches: [IncrementalSongStoreChangeBatch]) {
        var batches: [IncrementalSongStoreChangeBatch] = []
        let outcome = try store.scanner().replayChanges(
            after: revision, maximumRows: maximumRows, maximumRowsPerRevision: maximumRowsPerRevision
        ) { batches.append($0) }
        return (outcome, batches)
    }

    static func describe(_ batch: IncrementalSongStoreChangeBatch) -> String {
        let renames = batch.renaming.sorted { $0.key < $1.key }.map { "\($0.key)>\($0.value)" }.joined(separator: ",")
        return "r\(batch.storeRevision) rename[\(renames)] delete[\(batch.deletingIDs.joined(separator: ","))] "
            + "upsert[\(batch.upserts.map { "\($0.id)=\($0.title)" }.joined(separator: ","))]"
    }

    @Test("Each revision records what the apply did; an apply that changes nothing records nothing")
    func recordsWhatEachApplyDid() throws {
        let temporary = try TemporaryStore()
        let store = temporary.store
        let first = try store.apply(upserts: [Self.song("a"), Self.song("b"), Self.song("c")])
        #expect(try store.changeJournalState().entryCount == 3)

        // 没变的行不写、不记;删一个不在库里的 id、改一个不在库里的名,整次什么都没变:修订号不动,流水不长。
        #expect(try store.apply(upserts: [Self.song("a")]) == first)
        #expect(try store.apply(upserts: [], deletingIDs: ["missing"], renaming: ["nobody": "someone"]) == first)
        #expect(try store.changeJournalState().entryCount == 3)

        // 一次里改名、删除、写入都有:按做的先后记。改到已被占的名字的那一个没做,不记。
        var edited = Self.song("a2", title: "edited")
        edited.dateAdded = Date(timeIntervalSince1970: 1_700_000_100)
        let second = try store.apply(
            upserts: [edited, Self.song("d")], deletingIDs: ["a", "c"], renaming: ["a": "a2", "b": "c"]
        )
        #expect(second == first + 1)
        let replayed = try Self.replay(temporary, after: first)
        #expect(replayed.outcome == .replayed(storeRevision: second, revisions: 1, rows: 5, songCount: 3))
        #expect(replayed.batches.map(Self.describe) == ["r\(second) rename[a>a2] delete[a,c] upsert[a2=edited,d=t]"])

        // 从头重放:第一批写的 a 后来改名成了 a2,按 a2 现在的内容取、仍叫 a;c 后来删了,不写。
        let fromStart = try Self.replay(temporary, after: 0)
        #expect(fromStart.batches.map(Self.describe) == [
            "r\(first) rename[] delete[] upsert[a=edited,b=t]",
            "r\(second) rename[a>a2] delete[a,c] upsert[a2=edited,d=t]",
        ])
        // 没有新改动时什么都不交。
        #expect(try Self.replay(temporary, after: second).outcome == .replayed(storeRevision: second, revisions: 0, rows: 0, songCount: 3))
    }

    @Test("A replaced store, a pruned range, an oversized window and an oversized revision cannot be replayed")
    func unavailableCases() throws {
        let temporary = try TemporaryStore()
        let store = temporary.store
        let first = try store.apply(upserts: (0..<6).map { Self.song("s\($0)") })
        let second = try store.apply(upserts: [Self.song("s0", title: "again")])
        func isUnavailable(_ outcome: IncrementalSongStoreChangeReplay) -> Bool {
            if case .unavailable = outcome { return true }
            return false
        }
        // 一个修订号改得太多、整段太长:不重放(调用方整库对账)。
        #expect(isUnavailable(try Self.replay(temporary, after: 0, maximumRowsPerRevision: 5).outcome))
        #expect(isUnavailable(try Self.replay(temporary, after: 0, maximumRows: 6).outcome))
        #expect(try Self.replay(temporary, after: 0, maximumRows: 7, maximumRowsPerRevision: 6).batches.count == 2)
        // 目录镜像到的修订号比旧库还新(旧库被换回了旧的):不重放。
        #expect(isUnavailable(try Self.replay(temporary, after: second + 1).outcome))

        // 目录说镜像到了 `first`:下一次 apply 顺手剪掉不超过它的记录,起点推到 `first`。
        store.noteCatalogMirrored(revision: first)
        #expect(try store.changeJournalState().entryCount == 7)
        let third = try store.apply(upserts: [Self.song("s1", title: "third")])
        #expect(try store.changeJournalState().entryCount == 2)
        #expect(try store.changeJournalState().floor == first)
        // 从 `first` 接得上,从更早的地方接不上。
        #expect(try Self.replay(temporary, after: first).batches.map(Self.describe) == [
            "r\(second) rename[] delete[] upsert[s0=again]", "r\(third) rename[] delete[] upsert[s1=third]",
        ])
        #expect(isUnavailable(try Self.replay(temporary, after: first - 1).outcome))

        // 整份替换:流水清空,从新的修订号起算,之前的都接不上。
        let replaced = try store.replaceAll(with: [Self.song("x"), Self.song("y")])
        #expect(try store.changeJournalState().entryCount == 0)
        #expect(try store.changeJournalState().floor == replaced)
        #expect(isUnavailable(try Self.replay(temporary, after: third).outcome))
        #expect(try Self.replay(temporary, after: replaced).outcome == .replayed(storeRevision: replaced, revisions: 0, rows: 0, songCount: 2))
    }

    @Test("An apply that only marks a new store authoritative still gets its revision into the journal")
    func markerKeepsTheJournalContinuous() throws {
        let temporary = try TemporaryStore()
        let store = temporary.store
        // 新库头一次 apply 什么行都没动(要改名的那一行不在):只标成作数,修订号进一。
        let first = try store.apply(upserts: [], renaming: ["nobody": "someone"])
        #expect(first == 1)
        #expect(try store.changeJournalState().entryCount == 1)
        let second = try store.apply(upserts: [Self.song("a")])
        let replayed = try Self.replay(temporary, after: 0)
        #expect(replayed.outcome == .replayed(storeRevision: second, revisions: 2, rows: 1, songCount: 1))
        #expect(replayed.batches.map(Self.describe) == [
            "r\(first) rename[] delete[] upsert[]", "r\(second) rename[] delete[] upsert[a=t]",
        ])
    }

    @Test("A revision the journal did not record (a build without the journal wrote the store) cannot be replayed across")
    func unjournaledRevisionIsAGap() throws {
        let temporary = try TemporaryStore()
        let store = temporary.store
        let first = try store.apply(upserts: [Self.song("a"), Self.song("b")])
        // 旧版本写了一次:行变了、修订号进一,流水里没有。
        let stale = try store.apply(upserts: [Self.song("a", title: "old build")])
        do {
            var configuration = Configuration()
            configuration.journalMode = .wal
            let raw = try DatabaseQueue(path: temporary.path, configuration: configuration)
            try raw.write { db in
                try db.execute(
                    sql: "DELETE FROM \(IncrementalSongStore.ChangeJournal.table) WHERE revision = ?", arguments: [stale]
                )
            }
        }
        func isUnavailable(_ outcome: IncrementalSongStoreChangeReplay) -> Bool {
            if case .unavailable = outcome { return true }
            return false
        }
        #expect(isUnavailable(try Self.replay(temporary, after: first).outcome))
        // 之后新版本又写了一次:缺的那一次还是缺着,跨不过去;从它之后接得上。
        let third = try store.apply(upserts: [Self.song("b", title: "new build")])
        #expect(third == stale + 1)
        #expect(isUnavailable(try Self.replay(temporary, after: first).outcome))
        #expect(try Self.replay(temporary, after: stale).batches.map(\.storeRevision) == [third])
    }

    @Test("A journal over its capacity is emptied and starts again from that revision")
    func overflowResets() throws {
        let temporary = try TemporaryStore()
        let store = temporary.store
        let capacity = IncrementalSongStore.ChangeJournal.capacity
        // 一次就超:记完就清空。
        let first = try store.apply(upserts: (0...capacity).map { Self.song("big\($0)") })
        #expect(try store.changeJournalState().entryCount == 0)
        #expect(try store.changeJournalState().floor == first)
        // 之后照常记。
        let second = try store.apply(upserts: [Self.song("big0", title: "after")])
        #expect(try store.changeJournalState().entryCount == 1)
        #expect(try Self.replay(temporary, after: first).batches.map(\.storeRevision) == [second])
        if case .replayed = try Self.replay(temporary, after: first - 1).outcome {
            Issue.record("a catalog from before the overflow must not be able to replay")
        }
    }

    @Test("A store from before the journal starts one at its current revision; a new store can be replayed from the start")
    func olderStoreStartsAJournal() throws {
        // 新库:起点是 0,从头都接得上。
        let fresh = try TemporaryStore()
        let revision = try fresh.store.apply(upserts: [Self.song("a")])
        #expect(try fresh.store.changeJournalState().floor == 0)
        #expect(try Self.replay(fresh, after: 0).batches.count == 1)
        #expect(try Self.replay(fresh, after: revision).batches.isEmpty)

        // 旧版本留下的库(只有歌曲表和 meta,修订号已经走到 5):读的那一边先看到的是没有流水表。
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("store-journal-old-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("library-songs.sqlite").path
        do {
            var configuration = Configuration()
            configuration.journalMode = .wal
            let database = try DatabaseQueue(path: path, configuration: configuration)
            var migrator = DatabaseMigrator()
            migrator.registerMigration("v1_incremental_songs") { db in
                try db.create(table: "librarySongRecords") { table in
                    table.primaryKey("id", .text)
                    table.column("sourceID", .text).notNull().indexed()
                    table.column("orderKey", .integer).notNull()
                    table.column("payload", .blob).notNull()
                }
                try db.create(table: "libraryStoreMetadata") { table in
                    table.primaryKey("key", .text)
                    table.column("value", .text).notNull()
                }
            }
            try migrator.migrate(database)
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO libraryStoreMetadata (key, value)
                    VALUES ('songs-content-revision', '5'), ('songs-authoritative', '1')
                    """)
            }
        }
        func replayOld(after revision: Int64) throws -> (IncrementalSongStoreChangeReplay, Int) {
            var batches = 0
            let outcome = try IncrementalSongStoreScanner(path: path).replayChanges(
                after: revision, maximumRows: 100, maximumRowsPerRevision: 100
            ) { _ in batches += 1 }
            return (outcome, batches)
        }
        if case .replayed = try replayOld(after: 5).0 { Issue.record("a store without the journal table cannot be replayed") }
        // 新版本打开它:建表,流水从修订号 5 起算。这之前落后的目录接不上,这之后的接得上。
        let store = try IncrementalSongStore(path: path)
        #expect(try store.changeJournalState().floor == 5)
        #expect(try store.apply(upserts: [Self.song("a")]) == 6)
        let afterMigration = try replayOld(after: 5)
        #expect(afterMigration.0 == .replayed(storeRevision: 6, revisions: 1, rows: 1, songCount: 1))
        #expect(afterMigration.1 == 1)
        if case .replayed = try replayOld(after: 4).0 { Issue.record("changes before the journal existed cannot be replayed") }
    }

    @Test("The replay plan follows a row through later renames and drops what was deleted later")
    func replayPlan() throws {
        typealias Entry = StoreChangeJournalEntry
        func plan(_ entries: [Entry], revision: Int64 = 99) -> [String]? {
            StoreChangeReplayPlan(entries: entries, storeRevision: revision)?.revisions.map { revision in
                let renames = revision.renaming.sorted { $0.key < $1.key }.map { "\($0.key)>\($0.value)" }.joined(separator: ",")
                let upserts = revision.upserts.map { $0.id == $0.currentID ? $0.id : "\($0.id)@\($0.currentID)" }.joined(separator: ",")
                return "r\(revision.revision) rename[\(renames)] delete[\(revision.deletingIDs.joined(separator: ","))] upsert[\(upserts)]"
            }
        }
        // 写入、改名、再删:那一行最后没了,前面的写入不做。
        #expect(plan([
            Entry(revision: 5, kind: .upsert, id: "x"),
            Entry(revision: 6, kind: .rename, id: "x", newID: "y"),
            Entry(revision: 7, kind: .delete, id: "y"),
        ]) == ["r5 rename[] delete[] upsert[]", "r6 rename[x>y] delete[] upsert[]", "r7 rename[] delete[y] upsert[]"])
        // 两次改名:按最后的名字取,仍叫当时的 id。
        #expect(plan([
            Entry(revision: 5, kind: .upsert, id: "x"),
            Entry(revision: 6, kind: .rename, id: "x", newID: "y"),
            Entry(revision: 7, kind: .rename, id: "y", newID: "z"),
            Entry(revision: 8, kind: .upsert, id: "z"),
        ]) == ["r5 rename[] delete[] upsert[x@z]", "r6 rename[x>y] delete[] upsert[]", "r7 rename[y>z] delete[] upsert[]",
               "r8 rename[] delete[] upsert[z]"])
        // 删掉又加回来:前一份不写,后一份照写(目录里它会排到最后,同旧库)。
        #expect(plan([
            Entry(revision: 5, kind: .upsert, id: "x"),
            Entry(revision: 6, kind: .delete, id: "x"),
            Entry(revision: 7, kind: .upsert, id: "x"),
        ]) == ["r5 rename[] delete[] upsert[]", "r6 rename[] delete[x] upsert[]", "r7 rename[] delete[] upsert[x]"])
        // 同一个修订号里:改名、删旧名、写新名(App 改标签换身份时就是这样交的)。
        #expect(plan([
            Entry(revision: 4, kind: .upsert, id: "a"),
            Entry(revision: 5, kind: .rename, id: "a", newID: "b"),
            Entry(revision: 5, kind: .delete, id: "a"),
            Entry(revision: 5, kind: .upsert, id: "b"),
        ]) == ["r4 rename[] delete[] upsert[a@b]", "r5 rename[a>b] delete[a] upsert[b]"])
        // 改走之后旧名字又有了新的一行:两行各走各的。
        #expect(plan([
            Entry(revision: 5, kind: .rename, id: "x", newID: "y"),
            Entry(revision: 6, kind: .upsert, id: "x"),
            Entry(revision: 7, kind: .upsert, id: "y"),
        ]) == ["r5 rename[x>y] delete[] upsert[]", "r6 rename[] delete[] upsert[x]", "r7 rename[] delete[] upsert[y]"])
        // 一行都没动的修订号占一批空的。
        #expect(plan([
            Entry(revision: 5, kind: .marker, id: ""),
            Entry(revision: 6, kind: .upsert, id: "x"),
        ]) == ["r5 rename[] delete[] upsert[]", "r6 rename[] delete[] upsert[x]"])
        // 顺序不对、超过旧库修订号的:不成计划。
        #expect(plan([Entry(revision: 6, kind: .upsert, id: "x"), Entry(revision: 5, kind: .upsert, id: "y")]) == nil)
        #expect(plan([Entry(revision: 5, kind: .upsert, id: "x"), Entry(revision: 5, kind: .delete, id: "y")]) == nil)
        #expect(plan([Entry(revision: 100, kind: .upsert, id: "x")]) == nil)
        #expect(plan([Entry(revision: 5, kind: .rename, id: "x")]) == nil)
    }

    private struct Generator {
        var state: UInt64
        mutating func next(_ upperBound: Int) -> Int {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Int((state >> 33) % UInt64(upperBound))
        }
    }

    /// 目录里的歌按库内顺序:id 与标题。
    static func contents(of catalog: LibraryCatalog) throws -> [String] {
        var ids: [String] = []
        try catalog.forEachSongIdentity(.everything) { _, id, _ in
            ids.append(id)
            return true
        }
        return try catalog.songs(ids: ids).map { "\($0.id)=\($0.title)" }
    }

    /// 旧库里的歌按库内顺序。
    static func contents(of store: TemporaryStore) throws -> [String] {
        try store.store.loadSongs().map { "\($0.id)=\($0.title)" }
    }

    @Test(
        "A catalog that stopped at any revision and replays the journal equals one that followed every write, and the store",
        arguments: [1, 2, 3, 4, 5, 6] as [UInt64]
    )
    func replayMatchesFollowing(seed: UInt64) throws {
        var random = Generator(state: seed)
        let ids = (0..<9).map { "id\($0)" }
        for round in 0..<10 {
            let temporary = try TemporaryStore()
            let store = temporary.store
            let following = try TemporaryCatalog()
            let behind = try TemporaryCatalog()
            let batchCount = 4 + random.next(8)
            // 落后的那个目录跟到第 `stopAfter` 批为止。
            let stopAfter = random.next(batchCount)
            var mirroredRevision: Int64 = 0
            var lastRevision: Int64 = 0
            for index in 0..<batchCount {
                var upserts: [Song] = []
                for _ in 0..<random.next(4) {
                    upserts.append(Self.song(ids[random.next(ids.count)], title: "r\(round)b\(index)-\(random.next(1000))"))
                }
                var seen = Set<String>()
                upserts = upserts.reversed().filter { seen.insert($0.id).inserted }.reversed()
                var deletes: Set<String> = []
                for _ in 0..<random.next(3) { deletes.insert(ids[random.next(ids.count)]) }
                var renames: [String: String] = [:]
                for _ in 0..<random.next(3) { renames[ids[random.next(ids.count)]] = ids[random.next(ids.count)] }

                lastRevision = try store.apply(upserts: upserts, deletingIDs: deletes, renaming: renames)
                try following.catalog.apply(upserts: upserts, deletingIDs: deletes, renaming: renames)
                if index < stopAfter {
                    try behind.catalog.apply(upserts: upserts, deletingIDs: deletes, renaming: renames)
                    mirroredRevision = lastRevision
                    // 有时目录的确认已经到了旧库:之后的 apply 会剪掉这之前的流水。
                    if random.next(2) == 0 { store.noteCatalogMirrored(revision: lastRevision) }
                }
            }
            #expect(try Self.contents(of: following.catalog) == Self.contents(of: temporary), "seed \(seed) round \(round): following")

            // 追平:每个修订号一批,连同镜像到的修订号一个事务写进去。
            var appliedRevisions: [Int64] = []
            let outcome = try temporary.scanner().replayChanges(
                after: mirroredRevision, maximumRows: 10_000, maximumRowsPerRevision: 10_000
            ) { batch in
                try behind.catalog.apply(
                    upserts: batch.upserts, deletingIDs: batch.deletingIDs, renaming: batch.renaming,
                    mirrorMetadata: ["storeRevision": String(batch.storeRevision)]
                )
                appliedRevisions.append(batch.storeRevision)
            }
            guard case .replayed(let storeRevision, _, _, let songCount) = outcome else {
                Issue.record("seed \(seed) round \(round): \(outcome)")
                continue
            }
            #expect(storeRevision == lastRevision)
            #expect(try behind.catalog.songCount(.everything) == songCount, "seed \(seed) round \(round): row count")
            #expect(appliedRevisions == appliedRevisions.sorted() && appliedRevisions.allSatisfy { $0 > mirroredRevision })
            #expect(try Self.contents(of: behind.catalog) == Self.contents(of: following.catalog),
                    "seed \(seed) round \(round) stopped after \(stopAfter)/\(batchCount) at revision \(mirroredRevision)")
            #expect(try Self.contents(of: behind.catalog) == Self.contents(of: temporary), "seed \(seed) round \(round): store order")
            if let last = appliedRevisions.last {
                #expect(try behind.catalog.mirrorMetadata("storeRevision") == String(last))
            }
        }
    }

    @Test("A batch and the mirrored revision it carries are written together or not at all")
    func batchAndMirroredRevisionAreAtomic() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        try catalog.apply(upserts: [Self.song("a")], mirrorMetadata: ["storeRevision": "7"])
        #expect(try catalog.mirrorMetadata("storeRevision") == "7")
        // 写入失败(id 里有 U+0000,目录存不进去):这一批和它带的修订号都不留下。
        #expect(throws: (any Error).self) {
            try catalog.apply(upserts: [Self.song("b"), Self.song("bad\u{0}id")], mirrorMetadata: ["storeRevision": "8"])
        }
        #expect(try catalog.mirrorMetadata("storeRevision") == "7")
        #expect(try catalog.song(id: "b") == nil)
        // 什么都没变的一批照样记下修订号。
        try catalog.apply(upserts: [Self.song("a")], mirrorMetadata: ["storeRevision": "9"])
        #expect(try catalog.mirrorMetadata("storeRevision") == "9")
    }
}
