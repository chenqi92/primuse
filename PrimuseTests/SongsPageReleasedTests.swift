import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U5:歌曲页的「全部播放」「随机播放」在歌曲模型放掉之后从曲库目录拼整库的 id,与模型在内存里时相同,
/// 不装模型。目录给不出时先把模型装回来再拼(以前读到的是空数组,一首都不放)。
/// U5b:「播放次数」排序与页内查找也由目录给,与模型在内存里时内存路径排出、筛出的一样;iOS 的「来源」排序
/// 与 iOS 的内存排序同样按源 id 排名。
@MainActor
final class SongsPageReleasedTests: LibraryReleasedTwinTestCase {
    func testWholeLibraryPlaybackIDsComeFromTheCatalogWhileReleased() async throws {
        let songs = Self.fixture(prefix: "songs-page")
        let (library, _) = try makeLaunchedTwin("songs-page", songs: songs)
        await assertShadowMatches(library, "fixture")
        let loaded = library.musicSongIDsExcludingDisliked
        XCTAssertFalse(loaded.isEmpty)

        let before = try await releaseForReal(library)
        let released = await LibraryStartupPlaybackCoordinator.wholeLibraryPlaybackIDs(library: library)
        XCTAssertEqual(released, loaded, "the same ids from the catalog")
        assertNoLoadAndNoArrayRead(library, since: before, "whole-library play while released")
        // 目录给不出时的那条路(先装回模型再拼)走 `SongModelArrayRead`,它自己的测试管。
    }

    /// 目录给得出除「已下载」以外的每一种排序(「已下载」要等离线状态补全,页面另判)。
    func testTheCatalogServesEveryOrderButDownloaded() {
        for order in LibrarySongSortOrder.allCases {
            XCTAssertEqual(SongListCatalogPolicy.supports(order), order.criterion != .downloaded, order.rawValue)
        }
    }

    /// 模型在内存里时按内存路径排出、筛出的 id(计数有并列、有 0、有不在音乐里的歌),放掉之后目录那一份逐个相同;
    /// 查找结果的可播放数也一样;不装模型、不读整库数组。
    func testPlayCountOrderAndFindAnswerFromTheCatalogWhileReleased() async throws {
        let prefix = "songs-forms"
        let songs = Self.fixture(prefix: prefix)
        let (library, _) = try makeLaunchedTwin(prefix, songs: songs)
        await assertShadowMatches(library, "fixture")
        let music = library.musicSongs
        XCTAssertFalse(music.isEmpty)
        let counts = [
            "\(prefix)-blue-2": 3, "\(prefix)-comp-1": 3, "\(prefix)-loose": 1, "\(prefix)-cue-2": 1,
            "\(prefix)-blue-1": 0, "\(prefix)-book-1": 5, "\(prefix)-blueb-1": 4,
        ]
        let playCounts = LibrarySongPlayCounts(revision: UUID(), counts: counts)
        func key(_ order: LibrarySongSortOrder, find: String? = nil, counted: Bool = false) -> SongListCatalogList.Key {
            SongListCatalogList.Key(
                order: order, scope: .visibleMusic, baseScope: .visibleMusic,
                playCounts: counted ? playCounts : nil, find: find.flatMap(LibraryFindPolicy.query)
            )
        }
        func inMemory(_ order: LibrarySongSortOrder, find: String? = nil, counted: Bool = false) -> [String] {
            let sortValues = SongListSortValues(playCountsBySongID: counted ? counts : [:])
            let ordered = SongListSnapshotBuilder.build(songs: music, order: order, sortValues: sortValues).orderedSongIDs
            guard let query = find.flatMap(LibraryFindPolicy.query) else { return ordered }
            let byID = Dictionary(uniqueKeysWithValues: music.map { ($0.id, $0) })
            return ordered.filter { byID[$0].map { LibraryFindPolicy.matches(query, song: $0) } ?? false }
        }
        let cases: [(name: String, key: SongListCatalogList.Key, expected: [String])] = [
            ("play count", key(.playCount, counted: true), inMemory(.playCount, counted: true)),
            ("play count descending", key(.playCountDescending, counted: true), inMemory(.playCountDescending, counted: true)),
            ("play count without counts", key(.playCountDescending, counted: false), inMemory(.playCountDescending)),
            ("find blue", key(.title, find: "blue"), inMemory(.title, find: "blue")),
            // 键完全相等的行,目录按行号、降序时连行号一起倒(各排序原有的口径,见 Kit 的排序比对);这里用没有并列的排序。
            ("find two words", key(.dateAdded, find: "ＡＤＡ  room"), inMemory(.dateAdded, find: "ＡＤＡ  room")),
            ("find on play count", key(.playCountDescending, find: "comp", counted: true),
             inMemory(.playCountDescending, find: "comp", counted: true)),
            ("find nothing", key(.title, find: "no such song"), []),
        ]
        XCTAssertNotEqual(cases[0].expected, music.map(\.id), "the counts move songs")
        XCTAssertFalse(cases[3].expected.isEmpty)
        let playable = Dictionary(uniqueKeysWithValues: music.map { ($0.id, $0.isPlayable) })

        let before = try await releaseForReal(library)
        let host = try XCTUnwrap(library.catalogHost)
        for item in cases {
            let list = SongListCatalogList()
            let ready = await list.prepare(key: item.key, host: host)
            XCTAssertTrue(ready, item.name)
            XCTAssertEqual(list.count, item.expected.count, item.name)
            let ids = await list.orderedSongIDs()
            XCTAssertEqual(ids, item.expected, item.name)
            if item.key.find != nil {
                XCTAssertEqual(list.listPlayableCount, item.expected.filter { playable[$0] == true }.count, item.name)
                XCTAssertTrue(list.sections.isEmpty, "\(item.name): no letter index while finding")
            }
            list.reset()
        }
        assertNoLoadAndNoArrayRead(library, since: before, "play-count order and find while released")
    }

    /// iOS 的内存排序值是空的,「来源」排序比的是源 id;目录在 iOS 上也按源 id 排名(源名与 id 先后相反时也是),
    /// 分节字母一样;Mac 按源名(这里同一份目录按源名排出的源先后正好相反)。不装模型、不读整库数组。
    func testSourceOrderRanksSourcesLikeTheInMemorySortWhileReleased() async throws {
        XCTAssertEqual(SongListCatalogPolicy.sourceRanking, .id, "the iOS in-memory sort compares source ids")
        let prefix = "songs-source"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        // 源名的先后与 id 相反:按名排 B 在前,按 id 排 A 在前。
        library.updateCatalogSourceNames([Self.sourceA: "Zeta", Self.sourceB: "Alpha"])
        await library.waitForCatalogMirror()
        let loadedSongs = Dictionary(uniqueKeysWithValues: library.songs.map { ($0.id, $0) })

        let before = try await releaseForReal(library)
        let host = try XCTUnwrap(library.catalogHost)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let scope = LibrarySongScope(kinds: [.music], includesDisabledSources: true)
        let list = SongListCatalogList()
        let ready = await list.prepare(
            key: SongListCatalogList.Key(order: .source, scope: scope, baseScope: scope), host: host
        )
        XCTAssertTrue(ready)
        let ordered = await list.orderedSongIDs()
        let ids = try XCTUnwrap(ordered)
        let songs = ids.compactMap { loadedSongs[$0] }
        XCTAssertEqual(songs.count, ids.count)
        let inMemory = SongListSnapshotBuilder.build(songs: songs, order: .source, sortValues: .empty)
        // 同一个源里键完全相等的行,目录按行号、内存按 id(各排序原有的口径,另行处理);这里比源的先后与分节。
        func sources(_ ids: [String]) -> [String] { ids.compactMap { loadedSongs[$0]?.sourceID } }
        XCTAssertEqual(sources(ids), sources(inMemory.orderedSongIDs))
        XCTAssertEqual(Set(sources(ids)), [Self.sourceA, Self.sourceB])
        XCTAssertEqual(sources(ids).first, Self.sourceA, "by id: dual-write-a before dual-write-b")
        XCTAssertEqual(list.sections, inMemory.sectionIndexEntries)

        let byName = try await reader.read { try $0.songRowList(order: .source, scope: scope, sourceRanking: .name) }
        let nameIDs = try await reader.songIDs(rowids: byName.rowids, scope: scope)
        XCTAssertEqual(sources(nameIDs).first, Self.sourceB, "the Mac ranking (by name) puts Alpha first")
        assertNoLoadAndNoArrayRead(library, since: before, "source order while released")
    }
}
