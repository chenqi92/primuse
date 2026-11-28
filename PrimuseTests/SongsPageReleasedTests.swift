import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U5:歌曲页的「全部播放」「随机播放」在歌曲模型放掉之后从曲库目录拼整库的 id,与模型在内存里时相同,
/// 不装模型。目录给不出时先把模型装回来再拼(以前读到的是空数组,一首都不放)。
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
}
