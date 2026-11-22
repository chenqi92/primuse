import Foundation
import GRDB
import Testing
@testable import PrimuseKit

/// 目录的 SQL 排序与 `SongListSnapshotBuilder` 的比较器逐行一致(15 种排序 × 升降、分节索引、汇总)。
@Suite("Library catalog sort parity", .serialized)
struct LibraryCatalogSortParityTests {
    struct Fixture {
        let temporary: TemporaryCatalog
        let songs: [Song]
        let sortValues: SongListSortValues
    }

    static func makeFixture(seed: UInt64, count: Int) throws -> Fixture {
        var rng = CatalogTestRandom(seed: seed)
        var songs = (0..<count).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: false) }
        for index in songs.indices {
            songs[index] = songs[index].withoutAppliedPlaybackRange
            // 少量非 NFC 的 id:id 兜底要按 Swift 的字符串比较。
            if rng.chance(3) { songs[index].id = "id-e\u{301}-\(index)" }
            // 制造并列:同名、同年、同时长、同加入时间。
            if rng.chance(20) { songs[index].title = rng.pick(["Intro", "intro", "晴天", "e\u{301}", "\u{E9}"]) }
            if rng.chance(15) { songs[index].dateAdded = Date(timeIntervalSinceReferenceDate: 1_000) }
            if rng.chance(15) { songs[index].duration = 200 }
            if rng.chance(20) { songs[index].albumTitle = rng.pick(["Greatest Hits", "greatest hits", "叶惠美"]) }
        }
        var playCounts: [String: Int] = [:]
        var downloaded: Set<String> = []
        for song in songs {
            if rng.chance(30) { playCounts[song.id] = rng.int(0...5) }
            if rng.chance(25) { downloaded.insert(song.id) }
        }
        let sourceNames = ["src-smb": "家里的 NAS", "src-nas": "Beyond 盘", "src-サーバ": "家里的 NAS"]
        var indexItems: [String: SourceSyncIndexedItem] = [:]
        for song in songs where song.sourceID == "src-webdav" && rng.chance(60) {
            indexItems["path:" + song.filePath + song.id] = SourceSyncIndexedItem(
                stableKey: song.id, path: song.filePath, displayName: rng.maybe(80) { CatalogSongFactory.text(&$0) },
                parentPath: nil, isDirectory: rng.chance(5), songIDs: [song.id], size: 1,
                modifiedDate: nil, revision: nil
            )
        }
        let webdavIndex = SourceSyncIndex(indexItems)
        let sortValues = SongListSortValues(
            playCountsBySongID: playCounts,
            downloadedSongIDs: downloaded,
            sourceNamesByID: sourceNames,
            fileNameIndexesBySourceID: ["src-webdav": webdavIndex, "src-nas": SourceSyncIndex()]
        )

        let temporary = try TemporaryCatalog()
        try temporary.catalog.apply(upserts: songs)
        try temporary.catalog.setSourceNames(sourceNames.mapValues { Optional($0) })
        try temporary.catalog.setFileNameIndex(sourceID: "src-webdav", index: webdavIndex)
        try temporary.catalog.setFileNameIndex(sourceID: "src-nas", index: SourceSyncIndex())
        try temporary.catalog.setLocalPlayCounts(playCounts)
        try temporary.catalog.setDownloaded(true, songIDs: downloaded)
        return Fixture(temporary: temporary, songs: songs, sortValues: sortValues)
    }

    static func check(_ fixture: Fixture, seed: UInt64) throws {
        let catalog = fixture.temporary.catalog
        let scope = LibrarySongScope.everything
        var idByRowid: [Int32: String] = [:]
        let rowids = try catalog.rowids(forIDs: fixture.songs.map(\.id))
        for (song, rowid) in zip(fixture.songs, rowids) { idByRowid[rowid!] = song.id }
        for order in LibrarySongSortOrder.allCases {
            let expected = SongListSnapshotBuilder.build(songs: fixture.songs, order: order, sortValues: fixture.sortValues)
            let list = try catalog.songRowList(order: order, scope: scope, includeAggregates: true)
            let actual = list.rowids.map { idByRowid[$0]! }
            if actual != expected.orderedSongIDs {
                let mismatch = zip(actual, expected.orderedSongIDs).enumerated().first { $0.element.0 != $0.element.1 }
                Issue.record("seed \(seed) order \(order.rawValue): first mismatch at \(mismatch?.offset ?? -1): catalog \(mismatch?.element.0 ?? "-") vs builder \(mismatch?.element.1 ?? "-")")
            }
            #expect(list.sections == expected.sectionIndexEntries, "seed \(seed) order \(order.rawValue)")
            #expect(list.aggregates?.count == fixture.songs.count, "seed \(seed)")
            #expect(list.aggregates?.playableCount == expected.playableCount, "seed \(seed)")
            let duration = list.aggregates?.totalDuration ?? -1
            #expect(abs(duration - expected.totalDuration) <= max(1e-6, expected.totalDuration * 1e-12), "seed \(seed)")
        }
    }

    @Test("All 30 orders match the snapshot builder", arguments: [UInt64(11), 23, 57, 101, 404, 777, 1_234, 9_001])
    func parity(seed: UInt64) throws {
        let fixture = try Self.makeFixture(seed: seed, count: 700)
        try Self.check(fixture, seed: seed)
    }

    @Test("Parity holds after incremental edits and deletes")
    func parityAfterEdits() throws {
        let seed: UInt64 = 4_242
        let fixture = try Self.makeFixture(seed: seed, count: 500)
        var rng = CatalogTestRandom(seed: seed &+ 1)
        var songs = fixture.songs
        var deleted: [String] = []
        for index in songs.indices.reversed() where rng.chance(10) {
            deleted.append(songs.remove(at: index).id)
        }
        var edited: [Song] = []
        for index in songs.indices where rng.chance(20) {
            songs[index].title = CatalogSongFactory.text(&rng)
            songs[index].artistName = rng.pick(CatalogSongFactory.artists)
            songs[index].year = CatalogSongFactory.number(&rng, 50)
            edited.append(songs[index])
        }
        try fixture.temporary.catalog.apply(upserts: edited, deletingIDs: deleted)
        let remaining = Set(songs.map(\.id))
        let sortValues = SongListSortValues(
            playCountsBySongID: fixture.sortValues.playCountsBySongID.filter { remaining.contains($0.key) },
            downloadedSongIDs: fixture.sortValues.downloadedSongIDs.intersection(remaining),
            sourceNamesByID: fixture.sortValues.sourceNamesByID,
            fileNameIndexesBySourceID: fixture.sortValues.fileNameIndexesBySourceID
        )
        try Self.check(Fixture(temporary: fixture.temporary, songs: songs, sortValues: sortValues), seed: seed)
    }

    @Test("GRDB 7 registers the localized collations with Foundation semantics")
    func collationSemantics() throws {
        let temporary = try TemporaryCatalog()
        let row = try temporary.catalog.pool.read { db in
            try Row.fetchOne(db, sql: """
                SELECT 'a' < 'B' COLLATE swiftLocalizedCompare,
                       'a' < 'B',
                       'file2' < 'file10' COLLATE swiftLocalizedStandardCompare,
                       'file2' < 'file10' COLLATE swiftLocalizedCompare,
                       ('e' || char(769)) = char(233) COLLATE swiftLocalizedCompare
                """)!
        }
        #expect(row[0] as Int == 1)
        #expect(row[1] as Int == 0)
        #expect(row[2] as Int == 1)
        #expect(row[3] as Int == 0)
        #expect(row[4] as Int == 1)
        #expect(LibraryCatalogSchema.localizedCollation == "swiftLocalizedCompare")
        #expect(LibraryCatalogSchema.localizedStandardCollation == "swiftLocalizedStandardCompare")
        #expect(try temporary.catalog.collationLocaleIdentifier() == Locale.current.identifier)
    }

    @Test("A locale change rebuilds the localized indexes and records the new locale")
    func localeReindex() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("catalog-locale-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("c.sqlite").path
        do {
            let catalog = try LibraryCatalog(path: path, locale: Locale(identifier: "zz_TEST"))
            let stored = try catalog.collationLocaleIdentifier()
            #expect(stored == Locale(identifier: "zz_TEST").identifier)
        }
        let reopened = try LibraryCatalog(path: path, locale: .current)
        let stored = try reopened.collationLocaleIdentifier()
        #expect(stored == Locale.current.identifier)
    }

    @Test("Indexed orders use their covering index")
    func queryPlans() throws {
        let temporary = try TemporaryCatalog()
        let catalog = temporary.catalog
        let expectations: [(LibrarySongSortOrder, String)] = [
            (.title, "song_sort_title"), (.titleDescending, "song_sort_title_desc"),
            (.artist, "song_sort_artist"), (.album, "song_sort_album"),
            (.fileName, "song_sort_fileName"), (.fileNameDescending, "song_sort_fileName_desc"),
            (.dateAdded, "song_sort_dateAdded"),
            (.duration, "song_sort_duration"), (.year, "song_sort_year"),
        ]
        for (order, index) in expectations {
            let plan = LibraryCatalogSongSort.plan(for: order, idTerm: "s.id", sourceRank: "0")
            let detail = try catalog.pool.read { db in
                try Row.fetchAll(db, sql: """
                    EXPLAIN QUERY PLAN SELECT s.rowid FROM song AS s \(plan.joins)
                    WHERE s.kind = 0 AND s.sourceKey NOT IN (SELECT key FROM source WHERE enabled = 0)
                    ORDER BY \(plan.orderBy)
                    """).map { $0["detail"] as String }.joined(separator: " | ")
            }
            #expect(detail.contains(index), "\(order.rawValue): \(detail)")
            if order.isAscending {
                #expect(!detail.contains("TEMP B-TREE FOR ORDER BY"), "\(order.rawValue): \(detail)")
            }
        }
    }
}
