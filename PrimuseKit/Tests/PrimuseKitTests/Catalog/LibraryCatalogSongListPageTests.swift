import Foundation
import Testing
@testable import PrimuseKit

/// 歌曲页在目录上的「播放次数」排序与页内查找,与内存路径(`SongListSnapshotBuilder`、`LibraryFindPolicy`)逐行一致。
@Suite("Library catalog song list page forms", .serialized)
struct LibraryCatalogSongListPageTests {
    struct Fixture {
        let temporary: TemporaryCatalog
        let songs: [Song]
        let idByRowid: [Int32: String]
    }

    /// 写入顺序打乱(行号的先后不是 id 的先后);`exoticIDs` 混进非 ASCII 的 id(含非 NFC 的写法,
    /// 字节序与 Swift 的比较在这里不同)。
    static func makeFixture(seed: UInt64, count: Int, exoticIDs: Bool, exoticFields: Bool = false) throws -> Fixture {
        var rng = CatalogTestRandom(seed: seed)
        var songs = (0..<count).map { CatalogSongFactory.randomSong(&rng, index: $0, exotic: exoticFields) }
        for index in songs.indices {
            songs[index] = songs[index].withoutAppliedPlaybackRange
            songs[index].id = String(format: "%04x-%d", rng.int(0...0xFFFF), index)
            if exoticIDs, rng.chance(6) {
                songs[index].id = rng.pick(["id-e\u{301}-\(index)", "id-\u{E9}-\(index)", "Ｉ\(index)", "晴天-\(index)", "id-f\(index)"])
            }
        }
        for index in songs.indices.reversed() {
            songs.swapAt(index, rng.int(0...index))
        }
        let temporary = try TemporaryCatalog()
        try temporary.catalog.apply(upserts: songs)
        let rowids = try temporary.catalog.rowids(forIDs: songs.map(\.id))
        var idByRowid: [Int32: String] = [:]
        for (song, rowid) in zip(songs, rowids) {
            idByRowid[try #require(rowid)] = song.id
        }
        return Fixture(temporary: temporary, songs: songs, idByRowid: idByRowid)
    }

    static func playCounts(for songs: [Song], seed: UInt64) -> [String: Int] {
        var rng = CatalogTestRandom(seed: seed)
        var counts: [String: Int] = [:]
        for song in songs where rng.chance(40) {
            // 0 写进去也要与没写一样;次数挤在 1…3 之间,并列很多。
            counts[song.id] = rng.int(0...3)
        }
        counts["not-in-the-library"] = 9
        return counts
    }

    @Test(
        "Play-count order equals the comparator: (count, id), ties by id ascending in both directions",
        arguments: [(UInt64(31), false), (UInt64(32), true), (UInt64(33), true)]
    )
    func playCountOrder(seed: UInt64, exoticIDs: Bool) throws {
        let fixture = try Self.makeFixture(seed: seed, count: 700, exoticIDs: exoticIDs)
        let catalog = fixture.temporary.catalog
        let counts = Self.playCounts(for: fixture.songs, seed: seed &+ 1)
        // iOS 的内存排序不带计数:两边都是空的,就是 id 的先后。
        for table in [counts, [:]] {
            for ascending in [true, false] {
                let order: LibrarySongSortOrder = ascending ? .playCount : .playCountDescending
                let expected = SongListSnapshotBuilder.build(
                    songs: fixture.songs, order: order, sortValues: SongListSortValues(playCountsBySongID: table)
                ).orderedSongIDs
                let list = try catalog.songRowList(playCounts: table, ascending: ascending, scope: .everything)
                let actual = list.rowids.map { fixture.idByRowid[$0] ?? "?" }
                #expect(actual == expected, "seed \(seed) ascending \(ascending) counted \(table.count)")
                #expect(list.sections.isEmpty)
            }
        }

        // 范围:只要一个源;范围外的歌有计数也不进来。
        let sourceID = "src-nas"
        let scoped = fixture.songs.filter { $0.sourceID == sourceID }
        let expected = SongListSnapshotBuilder.build(
            songs: scoped, order: .playCountDescending, sortValues: SongListSortValues(playCountsBySongID: counts)
        ).orderedSongIDs
        let list = try catalog.songRowList(
            playCounts: counts, ascending: false, scope: LibrarySongScope(sourceID: sourceID, includesDisabledSources: true)
        )
        #expect(list.rowids.map { fixture.idByRowid[$0] ?? "?" } == expected, "seed \(seed) one source")
    }

    @Test("Find keeps exactly the rows the in-memory filter keeps, in the list's order, with their totals")
    func findMatchesTheInMemoryFilter() throws {
        let fixture = try Self.makeFixture(seed: 41, count: 600, exoticIDs: true, exoticFields: true)
        let catalog = fixture.temporary.catalog
        let songByID = Dictionary(uniqueKeysWithValues: fixture.songs.map { ($0.id, $0) })
        let queries = [
            "apple", "APPLE", "ａｐｐｌｅ", "Angstrom", "ÅNGSTRÖM", "e", "\u{E9}", "e\u{301}", "晴天", "晴天 周杰伦",
            "beyond 1991", "tail", "  love   night ", "taylor", "王菲", "カタカナ", "nothing-matches-this", "😀",
        ]
        for order in [LibrarySongSortOrder.title, .artistDescending, .dateAdded] {
            let base = try catalog.songRowList(order: order, scope: .everything)
            for raw in queries {
                let query = try #require(LibraryFindPolicy.query(raw))
                let expected = base.rowids.compactMap { rowid -> String? in
                    guard let id = fixture.idByRowid[rowid], let song = songByID[id],
                          LibraryFindPolicy.matches(query, song: song) else { return nil }
                    return id
                }
                let found = try catalog.songRowList(base, matching: query)
                #expect(found.rowids.map { fixture.idByRowid[$0] ?? "?" } == expected, "\(order.rawValue) “\(raw)”")
                #expect(found.sections.isEmpty)
                let matched = expected.compactMap { songByID[$0] }
                #expect(found.aggregates?.count == matched.count)
                #expect(found.aggregates?.playableCount == matched.filter(\.isPlayable).count, "“\(raw)”")
                let duration = matched.reduce(0.0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }
                let total = found.aggregates?.totalDuration ?? -1
                #expect(abs(total - duration) <= max(1e-6, duration * 1e-9), "“\(raw)”")
            }
        }
        // 至少有几个词真的筛出了东西、也真的筛掉了东西(否则上面的比对没意义)。
        let base = try catalog.songRowList(order: .title, scope: .everything)
        let apple = try catalog.songRowList(base, matching: try #require(LibraryFindPolicy.query("apple")))
        #expect(apple.count > 0 && apple.count < base.count)
    }

    @Test("Find on a play-count list and on one source keeps that list's order")
    func findOnOtherLists() throws {
        let fixture = try Self.makeFixture(seed: 51, count: 400, exoticIDs: true)
        let catalog = fixture.temporary.catalog
        let counts = Self.playCounts(for: fixture.songs, seed: 52)
        let query = try #require(LibraryFindPolicy.query("love"))
        let scope = LibrarySongScope(sourceID: "src-smb", includesDisabledSources: true)
        let scoped = fixture.songs.filter { $0.sourceID == "src-smb" }
        let expected = SongListSnapshotBuilder.build(
            songs: scoped, order: .playCountDescending, sortValues: SongListSortValues(playCountsBySongID: counts)
        ).orderedSongIDs.filter { id in
            fixture.songs.first { $0.id == id }.map { LibraryFindPolicy.matches(query, song: $0) } ?? false
        }
        let list = try catalog.songRowList(playCounts: counts, ascending: false, scope: scope)
        let found = try catalog.songRowList(list, matching: query)
        #expect(found.rowids.map { fixture.idByRowid[$0] ?? "?" } == expected)
        #expect(try catalog.songRowList(.empty, matching: query).isEmpty)
    }
}
