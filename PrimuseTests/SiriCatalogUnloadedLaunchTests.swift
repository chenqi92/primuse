import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U3 附带的启动遗留项:Siri 词表(书单、本机播客节目)在歌曲模型不在内存里时(放掉之后,
/// 或启动不装模型)从曲库目录答,与装着模型时相同;答的时候不装模型、不读整库数组。
/// 设备上找到的启动装载:播客节目的查询(按 id、按名字、快捷指令的建议)等的是「就绪」,系统每次启动来要建议时
/// 都把模型装了回来;现在等「可用」,本机播客从目录取。
@MainActor
final class SiriCatalogUnloadedLaunchTests: LibraryReleasedTwinTestCase {
    func testSiriVocabularyListsAnswerFromTheCatalogWhileReleased() async throws {
        let episodes = (1...3).map { index in
            Song(id: "siri-unloaded-episode-\(index)", title: "Episode \(index)", albumTitle: "Daily Show",
                 artistName: "Host", trackNumber: index, duration: 1_800, fileFormat: .mp3,
                 filePath: "/Podcasts/Daily/\(index).mp3", sourceID: Self.sourceA, genre: "Podcast")
        }
        let songs = Self.fixture(prefix: "siri-unloaded") + episodes
        let (library, _) = try makeLaunchedTwin("siri-unloaded", songs: songs)
        await assertShadowMatches(library, "fixture")
        let chaptersLoaded = library.spokenWordSongs.map(\.id)
        XCTAssertFalse(chaptersLoaded.isEmpty)
        let showsLoaded = SiriPodcastShow.catalog(
            subscriptions: [], libraryEpisodes: library.localPodcastSongs,
            libraryShowCount: library.localPodcastShowCount, limit: 50
        ) { id in
            guard let showID = library.localPodcastShowID(forSongID: id),
                  let title = library.localPodcastShowTitle(forSongID: id) else { return nil }
            return (showID, title)
        }.map { "\($0.id) \($0.title)" }
        XCTAssertFalse(showsLoaded.isEmpty, "the local episodes form a show")
        let showCountLoaded = library.localPodcastShowCount

        // 放掉之后与启动不装模型是同一个状态(可用、不在内存里),这几样都只问目录。
        let before = try await releaseForReal(library)
        let chapters = await AppServices.songsOutsideTheModel(kind: .spokenWord, library: library)?.map(\.id)
        XCTAssertEqual(chapters, chaptersLoaded, "book chapters from the catalog")
        let answer = await AppServices.siriPodcastCatalogOutsideTheModel(subscriptions: [], limit: 50, library: library)
        XCTAssertEqual(answer?.shows.map { "\($0.id) \($0.title)" }, showsLoaded, "local podcast shows from the catalog")
        XCTAssertEqual(answer?.libraryShowCount, showCountLoaded)
        assertNoLoadAndNoArrayRead(library, since: before, "Siri vocabulary while released")
        XCTAssertFalse(library.isReady)
    }

    static let episodes = (1...3).map { index in
        Song(id: "siri-podcast-episode-\(index)", title: "Episode \(index)", albumTitle: "Daily Show",
             artistName: "Host", trackNumber: index, duration: 1_800, fileFormat: .mp3,
             filePath: "/Podcasts/Daily/\(index).mp3", sourceID: LibraryReleasedTwinTestCase.sourceA, genre: "Podcast")
    }

    static func subscriptions() throws -> [PodcastShow] {
        try ["Morning News", "Daily Show Extra"].enumerated().map { offset, title in
            PodcastShow(id: "rss-\(offset)", feedURL: try XCTUnwrap(URL(string: "https://example.com/feed/\(offset)")),
                        title: title, subscribedAt: Date(timeIntervalSince1970: 1_700_000_000))
        }
    }

    /// 清单(全部订阅加本机播客)与快捷指令名额内的那份:模型在内存里时现算的,与放掉之后的答案逐项相同。
    static func podcastAnswers(
        _ library: MusicLibrary, subscriptions: [PodcastShow]
    ) async -> [String] {
        let all = await AppServices.siriPodcastCatalogAnswering(subscriptions: subscriptions, library: library)
        let shortcut = await AppServices.siriPodcastCatalogAnswering(
            subscriptions: subscriptions, limit: SiriListeningCatalog.podcastShowLimit, library: library
        )
        return all.map { "all \($0.id) \($0.title)" } + shortcut.map { "shortcut \($0.id) \($0.title)" }
    }

    func testPodcastShowQueriesAnswerFromTheCatalogWhileReleasedWithoutALoad() async throws {
        let (library, _) = try makeLaunchedTwin("siri-podcast", songs: Self.fixture(prefix: "siri-podcast") + Self.episodes)
        await assertShadowMatches(library, "fixture")
        let subscriptions = try Self.subscriptions()
        let loaded = await Self.podcastAnswers(library, subscriptions: subscriptions)
        XCTAssertGreaterThan(loaded.filter { $0.hasPrefix("all ") }.count, subscriptions.count, "the local show is listed too")
        XCTAssertTrue(loaded.contains("all rss-0 Morning News"))

        let before = try await releaseForReal(library)
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let released = await Self.podcastAnswers(library, subscriptions: subscriptions)
        XCTAssertEqual(released, loaded, "the same lists from the catalog")
        assertNoLoadAndNoArrayRead(library, since: before, "podcast show queries while released")
        XCTAssertEqual(songModelHolds(of: library), [], "nothing asked for the song model")
        XCTAssertFalse(library.isReady)
    }

    func testPodcastShowQueriesAnswerAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let songs = Self.fixture(prefix: "siri-podcast-launch") + Self.episodes
        let (source, storage) = try await launchFixture("siri-podcast-launch", songs: songs)
        let subscriptions = try Self.subscriptions()
        let loaded = await Self.podcastAnswers(source, subscriptions: subscriptions)
        let booksLoaded = AppServices.siriSpokenWordBooks(in: source).map { "\($0.id) \($0.items.map(\.id))" }
        XCTAssertFalse(booksLoaded.isEmpty)
        let directory = try copyOfDirectory(storage, "siri-podcast-launch-copy")

        let library = await launch(directory, unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        // 不等「可用」也不等目录:答案自己等(有界),像系统启动后马上来要建议那样(这时目录往往还读不了)。
        let answers = await Self.podcastAnswers(library, subscriptions: subscriptions)
        XCTAssertTrue(library.isUsable)
        XCTAssertEqual(answers, loaded, "the same lists as the loaded library")
        let books = await AppServices.siriSpokenWordBooksAnswering(library: library).map { "\($0.id) \($0.items.map(\.id))" }
        XCTAssertEqual(books, booksLoaded, "the same books (\"continue listening\" suggestions)")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0, "no load at launch")
        XCTAssertEqual(songModelHolds(of: library), [], "nothing asked for the song model")
        XCTAssertFalse(library.isReady)
    }
}
