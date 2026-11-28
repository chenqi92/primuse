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

    // MARK: Albums that a matching song brings in (C1)

    /// 夹具之外两首中文歌:歌名不在专辑名、艺人名里,给短汉字查询(要逐首扫的那一支)。
    static func songMatchFixture(prefix: String) -> [Song] {
        var songs = catalogFixture(prefix: prefix)
        for (offset, (title, album)) in [("夜曲", "十一月的萧邦"), ("稻香", "魔杰座")].enumerated() {
            var song = Song(
                id: "\(prefix)-han-\(offset)", title: title, albumTitle: album, artistName: "周杰伦", albumArtistName: "周杰伦",
                trackNumber: 1, discNumber: 1, duration: 240, fileFormat: .flac,
                filePath: "/Music/Jay/\(album)/\(offset).flac", sourceID: sourceA, genre: "Mandopop", year: 2005
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_300_000 + Double(offset))
            songs.append(song)
        }
        return songs
    }

    /// 只有歌名命中的(Mixtape、Live Set、Clips、十一月的萧邦、魔杰座)、专辑名也命中的、没有专辑的、什么都不中的。
    static let songMatchQueries = ["comp", "cue", "zebra", "mango", "loose", "co", "cu", "夜曲", "夜", "稻香", "blue", "hit", "1", "zz-none"]
    /// 全部命中种类,以及关掉元数据与模糊命中(专辑块开着时照样要搜元数据)。
    static let songMatchKinds: [Set<LibrarySearchMatchKind>] = [LibrarySearchMatchKind.all, [.path, .lyrics]]

    /// 搜索页全局搜索的那几步(`SearchView.performSearch`):目录给歌曲快照(P2c),`LibrarySearchIndex` 搜歌、带出专辑
    /// (先摆出来的那一行),再交给专辑、艺人的命中(先字面、再加拼音;歌名带出的专辑接在后面)。模型在内存里时交整份
    /// 数组、`scope` 为 nil;不在时交空数组与目录范围。
    private func songMatchedAlbums(
        _ library: MusicLibrary, index: LibrarySearchIndex, albums: [Album], artists: [Artist],
        scope: SearchCollectionCatalogScope?
    ) async throws -> [String: [String]] {
        let reader = try XCTUnwrap(P2cCatalogAccess.reader(for: library))
        let collections = LibraryCatalogSearchIndex()
        var result: [String: [String]] = [:]
        for query in Self.songMatchQueries {
            for kinds in Self.songMatchKinds {
                let label = "\(query) kinds=\(kinds.count)"
                let snapshot = try await LibrarySearchCatalogSnapshot.make(
                    reader: reader, query: query, matchKinds: kinds, wantsAlbums: SearchCatalogSupport.wantsAlbums(albums, scope),
                    songLimit: 120, sourceTypes: [:]
                )
                let indexed = await index.search(query: query, snapshot: snapshot, albums: albums, albumsByID: scope?.albumsByID,
                                                 metadataRevisionKey: "c1", matchKinds: kinds)
                let output = try XCTUnwrap(indexed, label).output
                result["\(label) interim"] = output.albumResults.map { "\($0.id)|\($0.title)|\($0.artistName ?? "-")" }
                for pinyin in [false, true] {
                    let group = await SearchCatalogSupport.collections(
                        index: collections, query: query, albums: albums, artists: artists,
                        relatedAlbums: output.albumResults, includePinyin: pinyin, catalog: scope
                    )
                    result["\(label) group pinyin=\(pinyin)"] = group.albums.map(\.id)
                }
            }
        }
        return result
    }

    /// 一个只给这个测试用的持久搜索索引,装进库里的歌(元数据、拼音、路径)。
    private func searchIndex(_ songs: [Song], _ name: String) async -> LibrarySearchIndex {
        let index = LibrarySearchIndex(storageDirectory: directory.appendingPathComponent("\(name)-search", isDirectory: true))
        await index.applyChanges(upserts: songs, deletingIDs: [], generation: LibrarySearchIndex.persistLibraryChangePending())
        return index
    }

    private func assertSongMatchFixtureIsUseful(_ expected: [String: [String]], _ library: MusicLibrary) throws {
        for (query, album) in [("comp", "Mixtape"), ("cue", "Live Set"), ("夜曲", "十一月的萧邦")] {
            let id = try XCTUnwrap(library.visibleAlbums.first { $0.title == album }?.id, album)
            for kinds in Self.songMatchKinds {
                XCTAssertEqual(expected["\(query) kinds=\(kinds.count) group pinyin=true"]?.contains(id), true,
                               "\(query): \(album) comes only from a song-title match")
            }
        }
    }

    func testAlbumsBroughtInByMatchingSongsWhileReleasedEqualTheModel() async throws {
        let prefix = "search-song-albums"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.songMatchFixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let index = await searchIndex(library.songs, prefix)
        let expected = try await songMatchedAlbums(
            library, index: index, albums: library.visibleAlbums, artists: library.visibleArtists, scope: nil
        )
        try assertSongMatchFixtureIsUseful(expected, library)
        XCTAssertNil(SearchCatalogSupport.collectionScope(library, albums: true, artists: true), "loaded: the arrays, as before")

        let before = try await releaseForReal(library)
        let scope = try XCTUnwrap(SearchCatalogSupport.collectionScope(library, albums: true, artists: true))
        XCTAssertNil(SearchCollectionCatalogScope(reader: scope.reader, catalog: scope.catalog, albums: false, artists: true,
                                                  revision: 0).albumsByID, "no albums wanted: no lookup")
        // C1 之前:模型不在内存里时交空数组、没有按 id 的读法,歌名带出的专辑一张都没有。
        let reader = try XCTUnwrap(P2cCatalogAccess.reader(for: library))
        let snapshot = try await LibrarySearchCatalogSnapshot.make(reader: reader, query: "comp", matchKinds: LibrarySearchMatchKind.all,
                                                                    wantsAlbums: false, songLimit: 120, sourceTypes: [:])
        let old = await index.search(query: "comp", snapshot: snapshot, albums: [], metadataRevisionKey: "c1-old")
        XCTAssertEqual(old?.output.albumResults.count, 0, "the gap this unit closes")
        let released = try await songMatchedAlbums(library, index: index, albums: [], artists: [], scope: scope)
        for key in expected.keys.sorted() {
            XCTAssertEqual(released[key], expected[key], "released: \(key)")
        }
        assertNoLoadAndNoArrayRead(library, since: before, "released")
    }

    func testAlbumsBroughtInByMatchingSongsAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let prefix = "search-song-albums-unloaded"
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let (source, storage) = try await launchFixture(prefix, songs: Self.songMatchFixture(prefix: prefix))
        let library = await launch(try copyOfDirectory(storage, "\(prefix)-launch"), unloaded: true)
        try await waitUntilUsable(library)
        try await waitUntil("catalog readable") { library.readableCatalogReader != nil }
        let stats = library.songModelResidencyStatistics
        XCTAssertEqual(stats.loads, 0)
        let index = await searchIndex(source.songs, prefix)
        // 同一份目录快照(这个库的),对照只差在专辑:内存里那份整份数组(装过模型的那个库的,内容相同)。
        let expected = try await songMatchedAlbums(
            library, index: index, albums: source.visibleAlbums, artists: source.visibleArtists, scope: nil
        )
        try assertSongMatchFixtureIsUseful(expected, source)
        let scope = try XCTUnwrap(SearchCatalogSupport.collectionScope(library, albums: true, artists: true))
        let launched = try await songMatchedAlbums(library, index: index, albums: [], artists: [], scope: scope)
        for key in expected.keys.sorted() {
            XCTAssertEqual(launched[key], expected[key], "unloaded launch: \(key)")
        }
        assertNoLoadAndNoArrayRead(library, since: stats, "unloaded launch")
    }
}
