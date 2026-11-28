import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

/// 6c 单元 4 U0:页面的占用(S1)与「不知道」的计数(S2),歌曲模型真放掉。
@MainActor
final class SongModelPageHoldTests: LibraryReleasedTwinTestCase {
    /// 还读整库数组的页面:模型在内存里时不拿占用;放掉之后不要数组的不拿、不装;要数组、看得见、在前台时拿
    /// `.legacyPage` 并装回来;进后台就放手(放得掉),回到前台再拿;页面消失也放手。
    func testAPageHoldIsTakenOnlyWhileReleasedAndIsDroppedInTheBackground() async throws {
        let (library, _) = try makeLaunchedTwin("page-hold", songs: Self.fixture(prefix: "page-hold"))
        await assertShadowMatches(library, "fixture")
        let page = SongModelPageHold()
        func holdsLegacyPage() -> Bool { library.songModelHoldReasons.contains(.legacyPage) }

        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertFalse(page.isHolding, "the model is loaded: no hold")
        XCTAssertFalse(holdsLegacyPage())

        let before = try await releaseForReal(library)
        page.update(library: library, needsArrays: false, isVisible: true, isActive: true)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(page.isHolding)
        assertNoLoadAndNoArrayRead(library, since: before, "a page that does not need the arrays")

        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertTrue(page.isHolding)
        try await waitUntilReady(library)
        XCTAssertTrue(library.isReady, "the page hold loaded the model")
        XCTAssertTrue(holdsLegacyPage())
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        let refused = await releaseOnceShadowVerificationIsDone(library, trigger: "test")
        XCTAssertEqual(refused, .skipped("hold(legacyPage)"), "a visible page keeps the model")

        // 进后台:放手,模型放得掉。
        page.update(library: library, needsArrays: true, isVisible: true, isActive: false)
        XCTAssertFalse(page.isHolding)
        XCTAssertFalse(holdsLegacyPage())
        let again = try await releaseForReal(library)

        // 回到前台、页面还在:再拿,再装回来;页面消失:放手。
        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertTrue(page.isHolding)
        try await waitUntilReady(library)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, again.loads + 1)
        page.update(library: library, needsArrays: true, isVisible: false, isActive: true)
        XCTAssertFalse(page.isHolding)
        XCTAssertFalse(holdsLegacyPage())
    }

    /// 等装载的途中放手(页面马上又消失了):占用撤掉,不留一个挡着放掉的占用。
    func testDroppingAPageHoldWhileTheModelLoadsLeavesNoHold() async throws {
        let (library, _) = try makeLaunchedTwin("page-hold-drop", songs: Self.fixture(prefix: "page-hold-drop"))
        await assertShadowMatches(library, "fixture")
        _ = try await releaseForReal(library)
        let page = SongModelPageHold()
        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        try await Task.sleep(for: .milliseconds(1))
        page.update(library: library, needsArrays: true, isVisible: false, isActive: true)
        try await waitUntilReady(library)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(page.isHolding)
        XCTAssertFalse(library.songModelHoldReasons.contains(.legacyPage), "no hold is left behind")
    }

    /// 分类的显示规则:电台、播客、有声书随时画;其余还读整库数组(本单元还没有分类改成读目录)。
    func testLibrarySectionsKeepTheirReadinessUntilTheyAreConverted() {
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .radio), .always)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .podcasts), .always)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .spokenWord), .always)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .songs), .legacy)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .albums), .catalog)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: .artists), .legacy)
        XCTAssertEqual(LibraryReadyContent<EmptyView>.readiness(for: nil), .legacy)
    }

    /// 计数(S2):模型在内存里时与数组的数相同;放掉之后目录计数还没读到时是 nil(不知道,不是 0),
    /// 读到之后是目录的数,与数组的相同;都不读整库数组、不装模型。
    func testSurfaceCountsAreUnknownRatherThanZeroWhileNothingCanAnswer() async throws {
        let (library, _) = try makeLaunchedTwin("surface-counts", songs: Self.fixture(prefix: "surface-counts"))
        await assertShadowMatches(library, "fixture")
        let music = library.musicSongs.count
        let visible = library.visibleSongs.count
        let albums = library.visibleAlbums.count
        let artists = library.visibleArtists.count
        let playable = library.visibleSongs.contains(where: \.isPlayable)
        XCTAssertGreaterThan(music, 0)

        let before = try await releaseForReal(library)
        XCTAssertNil(PlaybackSurfaceCountsModel.musicSongCount(in: library), "not read yet: unknown, not 0")
        XCTAssertNil(PlaybackSurfaceCountsModel.hasPlayableVisibleSong(in: library))
        for _ in 0..<250 where PlaybackSurfaceCountsModel.musicSongCount(in: library) == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(PlaybackSurfaceCountsModel.musicSongCount(in: library), music)
        XCTAssertEqual(PlaybackSurfaceCountsModel.visibleSongCount(in: library), visible)
        XCTAssertEqual(PlaybackSurfaceCountsModel.visibleAlbumCount(in: library), albums)
        XCTAssertEqual(PlaybackSurfaceCountsModel.visibleArtistCount(in: library), artists)
        XCTAssertEqual(PlaybackSurfaceCountsModel.hasPlayableVisibleSong(in: library), playable)
        assertNoLoadAndNoArrayRead(library, since: before, "surface counts while released")
    }
}
