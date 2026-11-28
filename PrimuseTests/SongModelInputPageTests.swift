import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 UB:「留住用户已有的」—— 编辑器在歌曲模型放掉后挂着、盖上加载、装回来揭开;Mac 首页的推荐在这次启动
/// 没装模型时取回上一次那组;「最近添加」的「查看全部」从目录按同样的顺序取;歌单导入答不了时不给结果。
/// 真放掉与真的「这次启动没装模型」两种状态都测。
@MainActor
final class SongModelInputPageTests: LibraryReleasedTwinTestCase {
    /// 状态机:还没显示过时等模型;显示过之后模型不在就盖着(不换成加载页),装回来就揭开;读目录的页不盖。
    func testTheLatchKeepsAnInputPageMountedAcrossARelease() {
        var latch = SongModelPageLatch(readiness: .legacy)
        XCTAssertEqual(latch.update(isUsable: false, isReady: false), .loading, "launch window: waits")
        XCTAssertEqual(latch.update(isUsable: true, isReady: false), .loading, "never shown, never loaded: waits")
        XCTAssertFalse(latch.hasShownContent)
        XCTAssertEqual(latch.update(isUsable: true, isReady: true), .content, "shown once")
        XCTAssertTrue(latch.hasShownContent)
        XCTAssertEqual(latch.update(isUsable: true, isReady: false), .covered, "released behind it: covered, still mounted")
        XCTAssertEqual(latch.update(isUsable: false, isReady: false), .covered)
        XCTAssertEqual(latch.update(isUsable: true, isReady: true), .content, "reloaded: uncovered")

        var catalogPage = SongModelPageLatch(readiness: .catalog)
        XCTAssertEqual(catalogPage.update(isUsable: true, isReady: false), .content)
        XCTAssertEqual(catalogPage.update(isUsable: true, isReady: true), .content)
        var always = SongModelPageLatch(readiness: .always)
        XCTAssertEqual(always.update(isUsable: false, isReady: false), .content)

        XCTAssertTrue(MacPageKind.smartPlaylistEditor.keepsInputOnRelease)
        XCTAssertFalse(MacPageKind.section(.songs).keepsInputOnRelease)
    }

    /// 真放掉:编辑器显示过,App 进后台时放手、模型放掉 → 盖着;回到前台再占用、装回来 → 揭开。
    func testAnInputPageIsCoveredWhileReleasedAndUncoveredAfterTheReload() async throws {
        let (library, _) = try makeLaunchedTwin("input-released", songs: Self.fixture(prefix: "input-released"))
        await assertShadowMatches(library, "fixture")
        var latch = SongModelPageLatch(readiness: .legacy)
        let page = SongModelPageHold()
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .content)
        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertFalse(page.isHolding, "loaded: no hold")

        page.update(library: library, needsArrays: true, isVisible: true, isActive: false)
        let before = try await releaseForReal(library)
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .covered)

        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertTrue(page.isHolding, "back in front: the page holds again")
        try await waitUntilReady(library)
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .content)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        page.update(library: library, needsArrays: true, isVisible: false, isActive: true)
        XCTAssertFalse(library.songModelHoldReasons.contains(.legacyPage))
    }

    /// 这次启动没装模型:编辑器先等(加载),占用把模型装回来后显示;之后放掉 → 盖着,回来 → 揭开。
    func testAnInputPageAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let (_, storage) = try await launchFixture("input-unloaded", songs: Self.fixture(prefix: "input-unloaded"))
        let library = await launch(try copyOfDirectory(storage, "input-unloaded-launch"), unloaded: true)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        try await waitUntilUsable(library)
        var latch = SongModelPageLatch(readiness: .legacy)
        let page = SongModelPageHold()
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .loading)
        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        XCTAssertTrue(page.isHolding)
        try await waitUntilReady(library)
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .content)

        page.update(library: library, needsArrays: true, isVisible: true, isActive: false)
        _ = try await releaseForReal(library)
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .covered)
        page.update(library: library, needsArrays: true, isVisible: true, isActive: true)
        try await waitUntilReady(library)
        XCTAssertEqual(latch.update(isUsable: library.isUsable, isReady: library.isReady), .content)
        page.update(library: library, needsArrays: true, isVisible: false, isActive: true)
    }

    /// Mac 首页「为你推荐」:模型在内存里时存下的那组,放掉之后、这次启动没装模型时按 id 取回来,
    /// 同样的歌、分数与理由,不装模型、不读整库数组。
    func testMacRecommendationsComeBackWithoutTheSongModel() async throws {
        let suite = "MacHomeRecommendations-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let (launched, _) = try makeLaunchedTwin("recommend-twin", songs: Self.fixture(prefix: "recommend"))
        await assertShadowMatches(launched, "fixture")
        let picks = ["recommend-blue-2", "recommend-comp-1", "recommend-cue-2"]
        let reasons: [[MusicDiscoveryReason]] = [[.sameArtist], [.sameGenre, .sameAlbum], []]
        let results = zip(picks, reasons).enumerated().compactMap { index, pick -> MusicDiscoveryResult? in
            launched.visibleSong(id: pick.0).map { MusicDiscoveryResult(song: $0, score: Double(10 - index), reasons: pick.1) }
        }
        XCTAssertEqual(results.count, 3)
        MacHomeRecommendationMemory.save(results, defaults: defaults)
        func picture(_ results: [MusicDiscoveryResult]) -> [String] {
            results.map { "\($0.song.id) \($0.song.title) \($0.score) \($0.reasons.map(\.rawValue))" }
        }

        let before = try await releaseForReal(launched)
        XCTAssertEqual(picture(MacHomeRecommendationMemory.restore(in: launched, defaults: defaults)), picture(results))
        assertNoLoadAndNoArrayRead(launched, since: before, "recommendations after a release")

        let (_, storage) = try await launchFixture("recommend", songs: Self.fixture(prefix: "recommend"))
        let unloaded = await launch(try copyOfDirectory(storage, "recommend-unloaded"), unloaded: true)
        XCTAssertEqual(unloaded.songModelLaunch, "unloaded")
        try await waitUntilUsable(unloaded)
        let start = unloaded.songModelResidencyStatistics
        XCTAssertEqual(picture(MacHomeRecommendationMemory.restore(in: unloaded, defaults: defaults)), picture(results),
                       "the first draw after a launch that did not load shows the last picks")
        assertNoLoadAndNoArrayRead(unloaded, since: start, "recommendations after an unloaded launch")
    }

    /// Mac 首页「最近添加」的「查看全部」:目录按页列出的顺序与成员与按整库数组排的相同(两种「显示外部专辑」),
    /// 模型在内存里、放掉之后、这次启动没装都一样;不装模型、不读整库数组。
    func testMacHomeRecentlyAddedPagesMatchTheArrays() async throws {
        let extras = MacHomeDashboardCatalogTests.dashboardExtras(prefix: "ra")
        let (library, _) = try makeLaunchedTwin("ra", songs: Self.fixture(prefix: "ra"), extra: extras)
        await assertShadowMatches(library, "fixture")
        var expected: [Bool: [String]] = [:]
        for including in [false, true] {
            expected[including] = MacHomeDashboardSnapshot.recentlyAddedAlbums(
                songs: library.musicSongs, albums: library.visibleAlbums, includingExternalSongs: including
            ).map(\.id)
        }
        XCTAssertNotEqual(expected[false], expected[true])
        func catalogPages(_ library: MusicLibrary, including: Bool) async throws -> [String] {
            let host = try XCTUnwrap(library.catalogHost)
            let query = MacHomeRecentlyAddedQuery(includingExternalSongs: including)
            let rowCache = host.reader.rowCache
            return try await host.reader.read { catalog in
                let rows = try query.fetchRows(catalog)
                let items = try query.materialize(Array(rows.ids), catalog: catalog, rowCache: rowCache)
                return rows.ids.compactMap { items[$0]?.id }
            }
        }
        for including in [false, true] {
            let loaded = try await catalogPages(library, including: including)
            XCTAssertEqual(loaded, expected[including], "loaded, including \(including)")
        }
        let before = try await releaseForReal(library)
        for including in [false, true] {
            let released = try await catalogPages(library, including: including)
            XCTAssertEqual(released, expected[including], "released, including \(including)")
        }
        assertNoLoadAndNoArrayRead(library, since: before, "recently added pages while released")

        let (_, storage) = try await launchFixture("ra-launch", songs: Self.fixture(prefix: "ra") + extras)
        let unloaded = await launch(try copyOfDirectory(storage, "ra-unloaded"), unloaded: true)
        try await waitUntilUsable(unloaded)
        let start = unloaded.songModelResidencyStatistics
        for including in [false, true] {
            let pages = try await catalogPages(unloaded, including: including)
            XCTAssertEqual(pages, expected[including], "never loaded, including \(including)")
        }
        assertNoLoadAndNoArrayRead(unloaded, since: start, "recently added pages after an unloaded launch")
    }

    /// 歌单导入在曲库目录答不了时拿整库对:放掉之后先装回来,拿到的与模型在内存里时相同;装不回来时抛取消
    /// (页面不给预览),不拿空数组对出「一首都对不上」。
    func testPlaylistImportMatchesAgainstTheLibraryOnlyOnceItIsBack() async throws {
        let (library, _) = try makeLaunchedTwin("import-pool", songs: Self.fixture(prefix: "import-pool"))
        await assertShadowMatches(library, "fixture")
        let loaded = try await PlaylistImportView.arrayMatchPool(library: library).map(\.id)
        XCTAssertFalse(loaded.isEmpty)
        let before = try await releaseForReal(library)
        let released = try await PlaylistImportView.arrayMatchPool(library: library).map(\.id)
        XCTAssertEqual(released, loaded)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)

        let (stuck, _) = try makeLaunchedTwin("import-pool-stuck", songs: Self.fixture(prefix: "import-pool-stuck"))
        await assertShadowMatches(stuck, "fixture")
        stuck.dropSongModelForMeasurement(includingCollections: true)
        do {
            _ = try await PlaylistImportView.arrayMatchPool(library: stuck, timeout: .milliseconds(200))
            XCTFail("cannot answer must not give an (empty) match pool")
        } catch is CancellationError {}
    }
}
