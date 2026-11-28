import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U7:搜索页在歌曲模型不在内存里时从曲库目录答 —— 专辑、艺人的命中(Q5:成员与先后,含同分时的先后)
/// 与交给内存里整份数组的那份相同;有声、环境音两组的条目同 `spokenWordSongs + localPodcastSongs`、`ambientSongs`;
/// 「资料库是空的」不在答不了时出现;计数;还要整库数组的两支才占用。模型放掉之后、这次启动没装模型两种状态,
/// 不装、不读整库数组。
@MainActor
final class SearchCatalogTests: LibraryReadyCatalogFixture {
    static let queries = ["blue", "a", "ada", "live", "v", "solo", "mix", "various", "hit", "room", "dj", "zz-none", "clip"]

    private struct Expected {
        var collections: [String: [String]] = [:]
        var spoken: [String] = []
        var ambient: [String] = []
        var counts: [String] = []
    }

    private func picture(_ output: LibraryCatalogSearchIndex.Output) -> [String] {
        output.albums.map { "album \($0.id)" } + output.artists.map { "artist \($0.id)" }
    }

    /// 模型在内存里时搜索页交给 `LibraryCatalogSearchIndex` 的那份(整份 `visibleAlbums` / `visibleArtists`)。
    private func expected(_ library: MusicLibrary) async -> Expected {
        var expected = Expected()
        let index = LibraryCatalogSearchIndex()
        for query in Self.queries {
            for pinyin in [false, true] {
                let output = await index.search(
                    query: query, albums: library.visibleAlbums, artists: library.visibleArtists, includePinyin: pinyin
                )
                expected.collections["\(query) \(pinyin)"] = picture(output)
            }
        }
        expected.spoken = (library.spokenWordSongs + library.localPodcastSongs).map(\.id)
        expected.ambient = library.ambientSongs.map(\.id)
        expected.counts = ["\(library.musicSongs.count)", "\(library.visibleAlbums.count)", "\(library.visibleArtists.count)"]
        return expected
    }

    private func assertCatalogSearch(
        _ library: MusicLibrary, _ expected: Expected, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertTrue(SearchCatalogSupport.answersFromCatalog(library), "\(step): from the catalog", file: file, line: line)
        let scope = try XCTUnwrap(SearchCatalogSupport.collectionScope(library, albums: true, artists: true),
                                  "\(step): catalog scope", file: file, line: line)
        XCTAssertNil(SearchCatalogSupport.collectionScope(library, albums: false, artists: false))
        for query in Self.queries {
            for pinyin in [false, true] {
                let output = await SearchCatalogSupport.collections(
                    index: LibraryCatalogSearchIndex(), query: query, albums: [], artists: [], includePinyin: pinyin,
                    catalog: scope
                )
                XCTAssertEqual(picture(output), expected.collections["\(query) \(pinyin)"],
                               "\(step): \(query) pinyin=\(pinyin)", file: file, line: line)
            }
        }
        let spoken = await SearchCatalogSupport.catalogSpokenSongs(library)
        XCTAssertEqual(spoken?.map(\.id), expected.spoken, "\(step): spoken-word space", file: file, line: line)
        let ambient = await SearchCatalogSupport.catalogAmbientSongs(library)
        XCTAssertEqual(ambient?.map(\.id), expected.ambient, "\(step): ambient space", file: file, line: line)
        XCTAssertEqual(SearchCatalogSupport.ambientSongsForPlayback(library).map(\.id), expected.ambient,
                       "\(step): ambient queue", file: file, line: line)
        XCTAssertFalse(SearchCatalogSupport.libraryIsEmpty(library), "\(step): never empty while answering",
                       file: file, line: line)
        try await waitUntil("\(step): counts") { LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts != nil }
        XCTAssertFalse(SearchCatalogSupport.libraryIsEmpty(library), "\(step): not empty", file: file, line: line)
        let counts: [SearchCatalogSupport.Count] = [.music, .albums, .artists]
        XCTAssertEqual(counts.map { SearchCatalogSupport.countText($0, library) }, expected.counts,
                       "\(step): counts", file: file, line: line)
        XCTAssertFalse(SearchCatalogSupport.needsTheSongModel(library, query: "a", scope: nil, intelligent: false))
        XCTAssertTrue(SearchCatalogSupport.needsTheSongModel(library, query: "a", scope: nil, intelligent: true),
                      "\(step): intelligent search holds", file: file, line: line)
        XCTAssertFalse(SearchCatalogSupport.needsTheSongModel(library, query: "", scope: nil, intelligent: true))
    }

    func testSearchFromTheCatalogEqualsTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("search-released", songs: Self.catalogFixture(prefix: "search-released"))
        await assertShadowMatches(library, "fixture")
        let expected = await expected(library)
        XCTAssertTrue(expected.collections.values.contains { $0.contains { $0.hasPrefix("artist") } }, "artist hits")
        XCTAssertTrue(expected.collections.values.contains { $0.contains { $0.hasPrefix("album") } }, "album hits")
        XCTAssertFalse(expected.spoken.isEmpty)
        XCTAssertFalse(expected.ambient.isEmpty)
        // 模型在内存里时:不从目录答,同以前。
        XCTAssertFalse(SearchCatalogSupport.answersFromCatalog(library))
        XCTAssertNil(SearchCatalogSupport.collectionScope(library, albums: true, artists: true))
        XCTAssertFalse(SearchCatalogSupport.needsTheSongModel(library, query: "a", scope: nil, intelligent: true))

        let before = try await releaseForReal(library)
        try await assertCatalogSearch(library, expected, "released")
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    func testSearchAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let unloaded = try await launchWithoutTheSongModel("search-unloaded")
        let stats = unloaded.library.songModelResidencyStatistics
        let expected = await expected(unloaded.source)
        try await assertCatalogSearch(unloaded.library, expected, "unloaded launch")
        assertNoLoadAndNoArrayRead(unloaded.library, since: stats, "unloaded launch")
    }
}
