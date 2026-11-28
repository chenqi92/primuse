import Foundation
import PrimuseKit
import SwiftUI
import XCTest
@testable import Primuse

/// 6c 单元 4 U2b:Mac 主窗口按「曲库可用」出来以后,各页的显示规则与占用 —— 放掉之后、和这次启动根本没装
/// 歌曲模型两种状态都测;删歌时共用旁挂文件的判断在模型放掉之后不再拿空数组当答案。
@MainActor
final class MacPageReadinessTests: LibraryReleasedTwinTestCase {
    /// 改成读目录的页随可用就画;电台、播客、有声随时画;其余还读整库数组。
    func testEachMacPageHasTheReadinessOfItsConversion() {
        XCTAssertEqual(MacPageKind.home.readiness, .catalog)
        XCTAssertEqual(MacPageKind.likedSongs.readiness, .catalog)
        XCTAssertEqual(MacPageKind.playlist.readiness, .catalog)
        XCTAssertEqual(MacPageKind.playlistDetail.readiness, .catalog)
        XCTAssertEqual(MacPageKind.section(.playlists).readiness, .catalog)
        XCTAssertEqual(MacPageKind.section(.albums).readiness, .catalog)
        XCTAssertEqual(MacPageKind.section(.albums).readiness, LibraryReadyContent<EmptyView>.readiness(for: .albums),
                       "same as the iPhone library section")
        XCTAssertEqual(MacPageKind.appleMusicArtist.readiness, .always)
        for section in [LibrarySection.radio, .podcasts, .spokenWord] {
            XCTAssertEqual(MacPageKind.section(section).readiness, .always, "\(section)")
            XCTAssertEqual(MacPageKind.section(section).readiness, LibraryReadyContent<EmptyView>.readiness(for: section),
                           "same as the iPhone library section")
        }
        let legacySections: [LibrarySection] = [
            .songs, .artists, .genres, .folders, .favorites, .releaseDate, .recommendations, .statistics,
            .ambient, .musicVideos,
        ]
        for section in legacySections {
            XCTAssertEqual(MacPageKind.section(section).readiness, .legacy, "\(section)")
        }
        let legacyPages: [MacPageKind] = [
            .listeningStats, .sources, .source, .search, .smartPlaylist, .albumDetail, .artistDetail,
            .smartPlaylistDetail, .searchCollection, .spokenWordBook, .tool, .recommendationsPanel, .smartPlaylistEditor,
        ]
        for page in legacyPages {
            XCTAssertEqual(page.readiness, .legacy, "\(page)")
        }

        // 主窗口等「可用」:可用之前什么页都不画(那时窗口本身是启动占位)。
        for readiness in [LibraryPageReadiness.catalog, .legacy] {
            XCTAssertFalse(MacPageKind.showsContent(readiness, isUsable: false, isReady: false))
        }
        XCTAssertTrue(MacPageKind.showsContent(.always, isUsable: false, isReady: false))
        XCTAssertTrue(MacPageKind.showsContent(.catalog, isUsable: true, isReady: false))
        XCTAssertFalse(MacPageKind.showsContent(.legacy, isUsable: true, isReady: false))
        for readiness in [LibraryPageReadiness.always, .catalog, .legacy] {
            XCTAssertTrue(MacPageKind.showsContent(readiness, isUsable: true, isReady: true))
        }
    }

    /// 模型真放掉之后:首页、歌单这些读目录的页直接画,不占用、不装、不读整库数组;歌曲页显示加载并占用
    /// `.legacyPage`,装回来就画,页面消失就放手。
    func testPagesAfterTheSongModelWasReleased() async throws {
        let (library, _) = try makeLaunchedTwin("mac-pages-released", songs: Self.fixture(prefix: "mac-pages-released"))
        await assertShadowMatches(library, "fixture")
        let before = try await releaseForReal(library)
        try await assertPageRules(library, before: before, "released after a load")
    }

    /// 这次启动没装歌曲模型(`PrimuseSongModelResidencyLaunchUnloaded`,前台不占用):窗口可用就出来;读目录的页
    /// 直接画、不装模型;还读数组的页加载、占用、装回来就画。
    func testPagesAfterALaunchThatDidNotLoadTheSongModel() async throws {
        let wait = MusicLibrary.unloadedLaunchCatalogWait
        MusicLibrary.unloadedLaunchCatalogWait = .seconds(10)
        defer { MusicLibrary.unloadedLaunchCatalogWait = wait }
        let directory = try await persistedLibraryCopy("mac-pages-unloaded")
        let library = await launchWithoutTheSongModel(directory)
        XCTAssertEqual(library.songModelLaunch, "unloaded")
        let deadline = ContinuousClock.now + .seconds(10)
        while !library.isUsable, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(library.isUsable, "the window comes up")
        XCTAssertFalse(library.isReady)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, 0)
        let before = library.songModelResidencyStatistics

        // 侧栏与首页(U2a)在这个状态下也从目录作答:计数读到之前是「不知道」,读到之后有数;首页快照有歌。
        let sources = [Self.sourceA, Self.sourceB]
        for _ in 0..<250 where MacSidebarCounts.current(
            library: library, artistMode: .allArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        ).music == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let counts = MacSidebarCounts.current(
            library: library, artistMode: .allArtists, hidesSingleOnlyAlbumArtists: false, sourceIDs: sources
        )
        XCTAssertGreaterThan(counts.music ?? 0, 0)
        XCTAssertGreaterThan(counts.albums ?? 0, 0)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        let dashboard = try await MacHomeDashboardSnapshot.fromCatalog(
            reader: reader, recentlyPlayedIDs: library.recentPlaybackSongIDsForSync, includingExternalSongs: false
        )
        XCTAssertEqual(dashboard.songCount, counts.music)
        XCTAssertEqual(dashboard.mosaicSongs.first?.id, "mac-pages-unloaded-blue-1", "the recently played song leads the mosaic")
        assertNoLoadAndNoArrayRead(library, since: before, "sidebar and Home without the model")

        try await assertPageRules(library, before: before, "never loaded at this launch")
    }

    private func assertPageRules(
        _ library: MusicLibrary, before: MusicLibrary.SongModelResidencyStatistics, _ state: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for kind in [MacPageKind.home, .playlist, .section(.playlists), .section(.radio)] {
            XCTAssertTrue(MacPageKind.showsContent(kind.readiness, isUsable: library.isUsable, isReady: library.isReady),
                          "\(state): \(kind) shows at once", file: file, line: line)
            let page = SongModelPageHold()
            page.update(library: library, needsArrays: kind.readiness == .legacy, isVisible: true, isActive: true)
            XCTAssertFalse(page.isHolding, "\(state): \(kind) does not hold", file: file, line: line)
        }
        try await Task.sleep(for: .milliseconds(100))
        assertNoLoadAndNoArrayRead(library, since: before, "\(state): converted pages", file: file, line: line)

        let songs = MacPageKind.section(.songs)
        XCTAssertFalse(MacPageKind.showsContent(songs.readiness, isUsable: library.isUsable, isReady: library.isReady),
                       "\(state): the songs page shows loading", file: file, line: line)
        let page = SongModelPageHold()
        page.update(library: library, needsArrays: songs.readiness == .legacy, isVisible: true, isActive: true)
        XCTAssertTrue(page.isHolding, "\(state): the songs page holds", file: file, line: line)
        try await waitUntilReady(library)
        XCTAssertTrue(library.isReady, "\(state): the hold brought the model", file: file, line: line)
        XCTAssertTrue(MacPageKind.showsContent(songs.readiness, isUsable: library.isUsable, isReady: library.isReady),
                      file: file, line: line)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1, file: file, line: line)
        page.update(library: library, needsArrays: true, isVisible: false, isActive: true)
        XCTAssertFalse(library.songModelHoldReasons.contains(.legacyPage), "\(state): dropped on leaving",
                       file: file, line: line)
    }

    /// 删一首歌时,另一首还用着的旁挂文件(CUE 分轨共用一个文件)不删:模型在内存里时与原来按 `library.songs`
    /// 判断的相同,不占用;放掉之后先装回来再判断,结果相同(拿放掉之后的空数组判断会删掉);不共用的照样删。
    func testDeletingASongKeepsSidecarsAnotherSongUsesWhileTheModelIsReleased() async throws {
        MusicLibrary.songModelHoldRequestsForTesting = []
        defer { MusicLibrary.songModelHoldRequestsForTesting = nil }
        let (library, _) = try makeLaunchedTwin("mac-sidecar", songs: Self.fixture(prefix: "mac-sidecar"))
        await assertShadowMatches(library, "fixture")
        let shared = try XCTUnwrap(library.songs.first { $0.id == "mac-sidecar-cue-1" })
        let alone = try XCTUnwrap(library.songs.first { $0.id == "mac-sidecar-loose" })
        func arraysAnswer(_ song: Song) -> Bool {
            SourceManager.sidecarDeletionSongIDs(deleting: [song], retaining: library.songs.filter { $0.id != song.id })
                .contains(song.id)
        }
        XCTAssertFalse(arraysAnswer(shared), "the other CUE track uses the same sidecars")
        XCTAssertTrue(arraysAnswer(alone))
        XCTAssertTrue(SourceManager.sidecarDeletionSongIDs(deleting: [shared], retaining: []).contains(shared.id),
                      "judged against an empty library the shared sidecars would be deleted")

        let loadedShared = await SongModelArrayRead.deletesSidecars(for: shared, in: library)
        let loadedAlone = await SongModelArrayRead.deletesSidecars(for: alone, in: library)
        XCTAssertFalse(loadedShared)
        XCTAssertTrue(loadedAlone)
        XCTAssertFalse(songModelHolds(of: library).contains(.userAction), "loaded: no hold")

        var before = try await releaseForReal(library)
        let releasedShared = await SongModelArrayRead.deletesSidecars(for: shared, in: library)
        XCTAssertFalse(releasedShared, "released: the sidecar another song uses stays")
        XCTAssertEqual(songModelHolds(of: library).filter { $0 == .userAction }.count, 1)
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
        XCTAssertFalse(library.songModelHoldReasons.contains(.userAction), "the hold ended after the decision")

        before = try await releaseForReal(library)
        let releasedAlone = await SongModelArrayRead.deletesSidecars(for: alone, in: library)
        XCTAssertTrue(releasedAlone, "released: a song's own sidecars are still deleted")
        XCTAssertEqual(library.songModelResidencyStatistics.loads, before.loads + 1)
    }

    /// 模型装不回来(这里:测量钩子放掉的库不会自己装载)时,判断「答不了」:连不共用的旁挂文件也留着,占用撤掉。
    func testASidecarDecisionThatCannotBeAnsweredKeepsTheFiles() async throws {
        let (library, _) = try makeLaunchedTwin("mac-sidecar-stuck", songs: Self.fixture(prefix: "mac-sidecar-stuck"))
        await assertShadowMatches(library, "fixture")
        let alone = try XCTUnwrap(library.songs.first { $0.id == "mac-sidecar-stuck-loose" })
        library.dropSongModelForMeasurement(includingCollections: true)
        XCTAssertFalse(library.isReady)
        let decision = await SongModelArrayRead.deletesSidecars(for: alone, in: library, timeout: .milliseconds(300))
        XCTAssertFalse(decision, "cannot answer: keep the files")
        let pool = await SongModelArrayRead.read(library, timeout: .milliseconds(100)) { 1 }
        XCTAssertNil(pool, "cannot answer is nil, not an empty answer")
        XCTAssertFalse(library.songModelHoldReasons.contains(.userAction), "the hold was withdrawn")
    }

    // MARK: - A launch that does not load the song model

    /// 一个落了盘、像启动过的库目录(小状态快照不带歌),拷一份给「启动」用。
    private func persistedLibraryCopy(_ name: String) async throws -> URL {
        let (library, storage) = try makeLaunchedTwin(name, songs: Self.fixture(prefix: name))
        library.recordPlayback(of: "\(name)-blue-1")
        await assertShadowMatches(library, "\(name) fixture")
        library.markPortableSnapshotDirtyForTesting()
        guard case .success = await library.persistNowAndWait(materializePortableSnapshot: true) else {
            throw XCTSkip("the fixture did not persist")
        }
        await library.waitForCatalogMirror()
        await library.stopCatalogMirror()
        let copy = directory.appendingPathComponent("\(name)-launch", isDirectory: true)
        var lastError: Error?
        for _ in 0..<5 {
            try? FileManager.default.removeItem(at: copy)
            do {
                try FileManager.default.copyItem(at: storage, to: copy)
                return copy
            } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw lastError ?? CocoaError(.fileWriteUnknown)
    }

    /// 像 App 打开 `PrimuseSongModelResidencyLaunchUnloaded`、关掉前台占用那样启动。
    private func launchWithoutTheSongModel(_ directory: URL) async -> MusicLibrary {
        let library = MusicLibrary.makePreparing(
            storageDirectory: directory, disabledSourceIDs: [Self.sourceB], artistNameConfiguration: .defaultValue,
            catalogMirroring: .enabled(startDelay: .zero)
        )
        library.catalogShadowModeOverride = .deep
        libraries.append(library)
        library.applySongModelResidencySettings(.init(
            isEnabled: true, foregroundHold: false, playbackBlocksRelease: true, launchUnloaded: true
        ))
        let classification = SpokenWordStore.shared.classificationSnapshot
        library.startCatalogBeforePublish(spokenWordClassification: classification)
        let disabled: Set<String> = [Self.sourceB]
        let prepared = await MusicLibrary.prepareStartup(
            disabledSourceIDs: disabled, storageDirectory: directory, artistNameConfiguration: .defaultValue,
            spokenWordClassification: classification, withoutTheSongModel: true
        )
        await library.publishStartup(prepared) {
            await MusicLibrary.prepareStartup(
                disabledSourceIDs: disabled, storageDirectory: directory, artistNameConfiguration: .defaultValue,
                spokenWordClassification: classification
            )
        }
        return library
    }
}
