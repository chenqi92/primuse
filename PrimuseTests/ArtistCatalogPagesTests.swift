import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U4b:艺术家页从曲库目录列 —— 「专辑艺术家」(`albumArtistBrowse`)与内存里的 `visibleAlbumArtists`
/// (`AlbumArtistIndexBuilder`)逐项相同(成员、先后、专辑数、歌曲数),按读音排的那一份同 iPhone 页的排法;
/// 页面的数据源(两种列法 × 两种先后 × 查找 × 只看喜欢)与内存路径同序;侧栏「专辑艺术家」的人数;模型放掉之后、
/// 这次启动没装模型时都答,不装、不读整库数组。
@MainActor
final class ArtistCatalogPagesTests: LibraryReadyCatalogFixture {
    private func picture(_ artists: [Artist]) -> [String] {
        artists.map { "\($0.id)|\($0.name)|\($0.albumCount)|\($0.songCount)" }
    }

    private struct Expected {
        let all: [Artist]
        let albumArtists: [Artist]
        let likedOrder: [String: Int]
        let likes: LibraryFavoritesStore
    }

    private func expected(_ library: MusicLibrary, name: String) throws -> Expected {
        let likes = LibraryFavoritesStore(fileURL: directory.appendingPathComponent("\(name)-likes.json"))
        likes.setLiked(true, artistNamed: "Various Artists")
        likes.setLiked(true, artistNamed: "Ada")
        likes.setLiked(true, artistNamed: "Nobody Here")
        return Expected(
            all: library.visibleArtists, albumArtists: library.visibleAlbumArtists,
            likedOrder: FavoriteCatalogLikes.likedOrder(likes, .artist), likes: likes
        )
    }

    /// 内存路径:列法、先后(iPhone 按读音)、只看喜欢、查找,与页面同一套。
    private func memoryList(_ expected: Expected, mode: ArtistBrowseMode, reading: Bool, search: String, liked: Bool) -> [Artist] {
        var list = mode == .allArtists ? expected.all : expected.albumArtists
        if reading {
            list = LibraryArtistBrowseLayoutBuilder.layout(artists: list, unknownArtistName: String(localized: "unknown_artist")).items
        }
        if liked { list = expected.likes.likedArtists(in: list) }
        return search.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func catalogList(_ library: MusicLibrary, _ query: LibraryArtistBrowseQuery) async throws -> [Artist] {
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let rows = try await reader.read { try query.fetchRows($0) }
        let ids = Array(rows.ids)
        let cache = reader.rowCache
        let items = try await reader.read { try query.materialize(ids, catalog: $0, rowCache: cache) }
        XCTAssertEqual(items.count, ids.count)
        return ids.compactMap { items[$0] }
    }

    private func assertCatalogPages(
        _ library: MusicLibrary, _ expected: Expected, _ step: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        XCTAssertTrue(expected.albumArtists.contains { $0.name == "Various Artists" }, "the fixture has an album-only artist")
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let browse = try await reader.read { try $0.albumArtistBrowse() }
        let byKey = try await reader.read { try $0.albumArtists(keys: browse.keys, in: browse) }
        XCTAssertEqual(picture(browse.keys.compactMap { byKey[$0] }), picture(expected.albumArtists),
                       "\(step): album artists", file: file, line: line)
        for mode in ArtistBrowseMode.allCases {
            for reading in [false, true] {
                for search in ["", "a"] {
                    for liked in [false, true] {
                        let query = LibraryArtistBrowseQuery(
                            unknownArtistName: String(localized: "unknown_artist"), search: search, mode: mode,
                            readingOrder: reading, likedOrder: liked ? expected.likedOrder : nil
                        )
                        let shown = try await catalogList(library, query)
                        let want = memoryList(expected, mode: mode, reading: reading, search: search, liked: liked)
                        XCTAssertEqual(picture(shown), picture(want),
                                       "\(step): \(mode) reading=\(reading) search=\(search) liked=\(liked)", file: file, line: line)
                    }
                }
            }
        }
        // 按读音排的分段与 iPhone 页的字母条一致。
        let reading = try await reader.read { try $0.albumArtistBrowse(order: .reading(unknownArtistName: String(localized: "unknown_artist"))) }
        let layout = LibraryArtistBrowseLayoutBuilder.layout(
            artists: expected.albumArtists, unknownArtistName: String(localized: "unknown_artist")
        )
        XCTAssertEqual(reading.sections, layout.sections, "\(step): sections", file: file, line: line)
        try await waitUntil("\(step): album-artist count") { AlbumArtistCatalogCount.current(in: library) == expected.albumArtists.count }
    }

    func testArtistPagesFromTheCatalogEqualTheModel() async throws {
        let (library, _) = try makeLaunchedTwin("artist-pages", songs: Self.catalogFixture(prefix: "artist-pages"))
        await assertShadowMatches(library, "fixture")
        let expected = try expected(library, name: "released")
        try await assertCatalogPages(library, expected, "loaded")
        // 模型在内存里:只有「全部艺术家」、不只看喜欢走目录(Mac 还要不在查找),同以前。
        XCTAssertNotNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .allArtists, likedOnly: false, search: "",
                                                 hidesSingles: false, requiresEmptySearch: true, library: library))
        XCTAssertNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: false, search: "",
                                              hidesSingles: false, requiresEmptySearch: true, library: library))
        XCTAssertNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .allArtists, likedOnly: false, search: "a",
                                              hidesSingles: false, requiresEmptySearch: true, library: library))

        let before = try await releaseForReal(library)
        try await assertCatalogPages(library, expected, "released")
        XCTAssertEqual(ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: true, search: "a",
                                                hidesSingles: false, requiresEmptySearch: true, library: library)?.mode,
                       .albumArtists, "released: album artists, find and liked come from the catalog")
        XCTAssertNotNil(ArtistCatalogKey.current(pagesLibrary: true, mode: .albumArtists, likedOnly: false, search: "",
                                                 hidesSingles: true, requiresEmptySearch: true, library: library)?.fullReleaseRevision,
                        "hiding single-only album artists reads the catalog's release categories (RC-b; the incomplete case "
                            + "is in ReleaseCategoryPagesCatalogTests)")
        XCTAssertNil(ArtistCatalogKey.current(pagesLibrary: false, mode: .allArtists, likedOnly: false, search: "",
                                              hidesSingles: false, requiresEmptySearch: true, library: library),
                     "a supplied list is not paged")
        try await waitUntil("hub counts") { LibraryHubCatalogCountsModel.shared(for: library)?.readableCounts != nil }
        XCTAssertFalse(ArtistCatalogKey.libraryHasNoArtists(library))
        try await waitUntil("sidebar album-artist count") {
            MacSidebarCounts.current(library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: false,
                                     sourceIDs: []).artists == expected.albumArtists.count
        }
        try await waitUntil("sidebar count with single-only album artists hidden (RC-b)") {
            MacSidebarCounts.current(library: library, artistMode: .albumArtists, hidesSingleOnlyAlbumArtists: true,
                                     sourceIDs: []).artists != nil
        }
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    func testArtistPagesAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let unloaded = try await launchWithoutTheSongModel("artist-unloaded")
        let stats = unloaded.library.songModelResidencyStatistics
        let expected = try expected(unloaded.source, name: "unloaded")
        try await assertCatalogPages(unloaded.library, expected, "unloaded launch")
        assertNoLoadAndNoArrayRead(unloaded.library, since: stats, "unloaded launch")
    }
}
