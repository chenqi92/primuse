import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U1b:首页几个区块在歌曲模型放掉之后从曲库目录答,与模型在内存里时相同,不装模型、不读整库数组。
///
/// `musicVideoSongs`、`localPodcastBookIDs` 的读不在数组读的诊断里(S8 第 1 项还没做):放掉之后读到的是空的,
/// 所以这里的证明是「放掉之后的答案与装着时相同」,读到空数组就对不上。
@MainActor
final class HomeSectionsReleasedTests: LibraryReleasedTwinTestCase {
    func testMusicVideoShelfAndPodcastResumeAnswerFromTheCatalogWhileReleased() async throws {
        var songs = Self.fixture(prefix: "home-sections")
        songs[0].mvPath = "/Videos/blue-1.mp4"
        songs[4].mvPath = "/Videos/comp-1.mp4"
        songs[16].mvPath = "/Videos/cue-1.mp4"
        let episodes = (1...3).map { index in
            Song(id: "home-sections-episode-\(index)", title: "Episode \(index)", albumTitle: "Daily Show",
                 artistName: "Host", trackNumber: index, duration: 1_800, fileFormat: .mp3,
                 filePath: "/Podcasts/Daily/\(index).mp3", sourceID: Self.sourceA, genre: "Podcast")
        }
        let (library, _) = try makeLaunchedTwin("home-sections", songs: songs, extra: episodes)
        await assertShadowMatches(library, "fixture")
        XCTAssertEqual(library.musicVideoSongs.count, 3)

        let request = MusicVideoRecommendationPolicy.Request(
            catalogRevision: 1, favoriteArtistIDs: [songs[4].artistID].compactMap { $0 },
            recentlyPlayedIDs: [songs[0].id], day: 20_261_127, limit: 6
        )
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let videosLoaded = await HomeMusicVideoPicks.picks(for: request, library: library, now: now)?.map(\.id)
        XCTAssertEqual(videosLoaded?.count, 3)

        let progress = SpokenWordStore(storeURL: directory.appendingPathComponent("home-sections-progress.json"))
        progress.rememberPosition(300, duration: 1_800, forSongID: episodes[1].id)
        progress.rememberPosition(120, duration: 1_800, forSongID: episodes[0].id)
        func resume() -> [String] {
            PodcastResumeItem.recent(in: library, limit: 3, progress: progress, subscription: { _ in nil }).map { item in
                guard case .library(let song, let showID, let showTitle) = item.source else { return "subscription" }
                return "\(song.id) \(showID) \(showTitle)"
            }
        }
        let resumeLoaded = resume()
        XCTAssertEqual(resumeLoaded.count, 2, "both local episodes with progress are offered: \(resumeLoaded)")

        let before = try await releaseForReal(library)
        let videosReleased = await HomeMusicVideoPicks.picks(for: request, library: library, now: now)?.map(\.id)
        XCTAssertEqual(videosReleased, videosLoaded, "the MV shelf from the catalog")
        XCTAssertEqual(resume(), resumeLoaded, "local podcasts stay in continue listening, with their show")
        assertNoLoadAndNoArrayRead(library, since: before, "Home sections while released")
    }
}
