import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U3 附带的启动遗留项:Siri 词表(书单、本机播客节目)在歌曲模型不在内存里时(放掉之后,
/// 或启动不装模型)从曲库目录答,与装着模型时相同;答的时候不装模型、不读整库数组。
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
}
