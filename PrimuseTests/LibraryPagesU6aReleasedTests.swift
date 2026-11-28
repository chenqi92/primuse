import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U6a:流派页与流派详情、环境音页、重复歌曲页的查找、智能歌单(规则歌单)在歌曲模型放掉之后从曲库目录
/// 作答,与模型在内存里时相同;答的时候不装模型、不读整库数组。
@MainActor
final class LibraryPagesU6aReleasedTests: LibraryReleasedTwinTestCase {
    /// 夹具之外加两首「同一首歌的另一份文件」(同名、同艺人、同时长,不同路径与格式),让重复歌曲页有东西找。
    static func duplicates(prefix: String) -> [Song] {
        (1...2).map { copy in
            var song = Song(
                id: "\(prefix)-blue-1-copy-\(copy)", title: "Blue 1", albumTitle: "Blue Room", artistName: "Ada",
                albumArtistName: "Ada", trackNumber: 1, discNumber: 1, duration: 180, fileFormat: copy == 1 ? .mp3 : .m4a,
                filePath: "/Copies/\(copy)/Blue 1.\(copy == 1 ? "mp3" : "m4a")", sourceID: sourceA, genre: "Pop", year: 2001
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_100_000 + Double(copy))
            return song
        }
    }

    func testGenresAndGenreDetailAnswerFromTheCatalogWhileReleased() async throws {
        let prefix = "u6a-genres"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        func picture(_ genres: [LibraryGenre]) -> [String] {
            genres.map { "\($0.id)|\($0.name)|\($0.songCount)|\($0.albumCount)|\($0.representativeSongIDs)" }.sorted()
        }
        let genresLoaded = picture(library.visibleGenres)
        XCTAssertGreaterThan(genresLoaded.count, 1)
        let detailLoaded = library.visibleGenres.map { genre in
            "\(genre.id) songs=\(library.songIDs(forGenre: genre.id)) albums=\(library.albums(forGenre: genre.id).map(\.id))"
        }.sorted()

        let before = try await releaseForReal(library)
        let host = try XCTUnwrap(library.catalogHost)
        let list = GenreCatalogList()
        list.activate(host: host)
        defer { list.deactivate() }
        let deadline = ContinuousClock.now + .seconds(5)
        while list.readableGenres == nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let genres = try XCTUnwrap(list.readableGenres, "the page's catalog list arrives while released")
        XCTAssertEqual(picture(genres), genresLoaded, "the same genres, counts and card covers")
        let detail = genres.map { genre in
            "\(genre.id) songs=\(library.songIDs(forGenre: genre.id)) albums=\(library.albums(forGenre: genre.id).map(\.id))"
        }.sorted()
        XCTAssertEqual(detail, detailLoaded, "the genre pages' songs and albums")
        assertNoLoadAndNoArrayRead(library, since: before, "genres while released")
    }

    func testAmbientSoundsAnswerFromTheCatalogWhileReleased() async throws {
        let prefix = "u6a-ambient"
        let rain = (1...3).map { index in
            Song(id: "\(prefix)-sound-\(index)", title: "Sound \(index)", albumTitle: "Sleep", artistName: "Nature",
                 trackNumber: index, duration: 600, fileFormat: .flac, filePath: "/Ambient/sound-\(index).flac",
                 sourceID: Self.sourceA, genre: "White Noise")
        }
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix) + rain)
        await assertShadowMatches(library, "fixture")
        let loaded = library.ambientSongs.map(\.id)
        XCTAssertGreaterThan(loaded.count, 1)

        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let released = try await AmbientSoundBoard.catalogAmbientSongs(reader).map(\.id)
        XCTAssertEqual(released, loaded, "the same sounds in library order")
        assertNoLoadAndNoArrayRead(library, since: before, "ambient sounds while released")
    }

    func testDuplicateScanAnswersFromTheCatalogWhileReleased() async throws {
        let prefix = "u6a-duplicates"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix) + Self.duplicates(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        func picture(_ groups: [DuplicateGroup]) -> [String] {
            groups.map { "\($0.id)|\($0.title)|\($0.songs.map(\.id))" }.sorted()
        }
        let loaded = picture(DuplicateDetector.detect(in: library.visibleSongs))
        XCTAssertFalse(loaded.isEmpty, "the fixture has a duplicate group")

        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let released = picture(try await DuplicateCatalogScan.detect(reader: reader))
        XCTAssertEqual(released, loaded, "the same groups, best copy first")
        assertNoLoadAndNoArrayRead(library, since: before, "duplicate scan while released")
    }

    /// 规则歌单(任何规则字段都在目录上逐首照同一份编译好的规则算,见双写测试里的 150 步随机比对)放掉之后照样从目录
    /// 作答;AI 歌单按身份对回要整库数组,详情页那时替自己占用(`matchToken` 是 `.uncached`)。
    func testRulePlaylistsMatchOnTheCatalogWhileReleased() async throws {
        let prefix = "u6a-smart"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let smart = SmartPlaylist(
            id: "\(prefix)-ada", name: "Ada",
            ruleGroups: [SmartPlaylistRuleGroup(
                rules: [SmartPlaylistRule(field: .artistName, op: .contains, value: "Ada")], combinator: .and, isExcluded: false
            )],
            groupCombinator: .and, limit: nil, sortField: .title, sortDirection: .ascending
        )
        let history = PlayHistoryStore.shared
        let loaded = SmartPlaylistEngine.match(smart, in: library, history: history).map(\.id)
        XCTAssertFalse(loaded.isEmpty)

        let before = try await releaseForReal(library)
        guard case .catalog = SmartPlaylistEngine.matchToken(for: smart, in: library, history: history) else {
            return XCTFail("a rule playlist matches on the catalog while released")
        }
        let released = await SmartPlaylistEngine.matchedSongIDs(smart, in: library, history: history)
        XCTAssertEqual(released, loaded, "the same songs in the same order")
        assertNoLoadAndNoArrayRead(library, since: before, "rule playlist while released")
    }
}
