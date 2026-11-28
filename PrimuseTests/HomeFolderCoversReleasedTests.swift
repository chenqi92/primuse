import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U3c:文件夹卡片(首页目录区、目录页、资料库收藏的目录)的封面在歌曲模型放掉之后不再在视图里逐首读目录 ——
/// 首页会摆的那几个文件夹在后台从曲库目录预挑(`HomeFolderCoverPrewarm.fromCatalog`),挑出的与模型在内存里时按可见歌
/// 预挑的相同(同一组文件夹、每个文件夹按文件夹里的先后前四首有封面的);没预挑过的文件夹在卡片显示时排队在后台挑,
/// 挑出的与内存里按同一条规则挑的相同。不装模型、不读整库数组。
@MainActor
final class HomeFolderCoversReleasedTests: LibraryReadyCatalogFixture {
    /// 一个大文件夹:前 120 首没有封面,第 121 首的封面名是空串(算有,同内存),最后两首有封面 —— 要按段走过好几段。
    private static func bigFolder(prefix: String) -> [Song] {
        (0..<150).map { index in
            var song = Song(
                id: "\(prefix)-big-\(index)", title: "Big \(index)", albumTitle: "Cloud", artistName: "Uploader",
                trackNumber: index + 1, discNumber: 1, duration: 120, fileFormat: .mp3,
                filePath: "/Music/Cloud/Big/\(index).mp3", sourceID: sourceA, genre: "Pop",
                coverArtFileName: index == 120 ? "" : (index >= 148 ? "big-\(index).jpg" : nil)
            )
            song.dateAdded = Date(timeIntervalSince1970: 1_700_300_000 + Double(index))
            return song
        }
    }

    func testFolderCoversAreChosenFromTheCatalogOffTheMainThreadWhileReleased() async throws {
        let prefix = "home-covers"
        var songs = Self.fixture(prefix: prefix)
        songs[5].coverArtFileName = "comp-2.jpg"
        songs[11].coverArtFileName = "chapter-2.jpg"
        let big = Self.bigFolder(prefix: prefix)
        let (library, _) = try makeLaunchedTwin(prefix, songs: songs, extra: big)
        await assertShadowMatches(library, "fixture")
        let memoryIndex = LibraryHubPinsReleasedTests.memoryFolderIndex(library)
        let bigNode = try XCTUnwrap(memoryIndex.nodeID(containingSongID: big[0].id))
        let pins = HomeFolderCoverPrewarm.Pins(raw: HomeFolderPinStorage.encode([bigNode]), displayCount: 3)
        let lookup = library.visibleSongLookup()
        let loaded = HomeFolderCoverPrewarm.fromMemory(memoryIndex, lookup: lookup, pins: pins) { false }
        XCTAssertTrue(loaded.pinnedNodeIDs.contains(bigNode), "the pinned folder is among the prewarmed ones")
        XCTAssertEqual(loaded.covers[bigNode].map { Array($0.suffix(2)) }, [big[148].id, big[149].id], "the big folder's covers")
        var expectedPicks: [LibraryFolderNodeID: [String]] = [:]
        var pending = memoryIndex.sourceNodeIDs
        while let id = pending.popLast() {
            expectedPicks[id] = memoryIndex.firstSongIDs(in: id, limit: 4) { lookup.song(id: $0)?.coverArtFileName != nil }
            pending.append(contentsOf: memoryIndex.children(of: id).map(\.id))
        }
        XCTAssertGreaterThan(expectedPicks.count, 3)

        let before = try await releaseForReal(library)
        let catalogIndex = try await LibraryHubPinsReleasedTests.catalogFolderIndex(library)
        let catalog = try XCTUnwrap(library.catalogHost?.mirror.readableCatalog)
        let released = try XCTUnwrap(HomeFolderCoverPrewarm.fromCatalog(catalogIndex, catalog: catalog, pins: pins) { false })
        XCTAssertEqual(released.pinnedNodeIDs, loaded.pinnedNodeIDs, "the same folders are prewarmed")
        XCTAssertEqual(released.covers, loaded.covers, "the same cover songs per folder, in folder order")
        XCTAssertEqual(Set(released.songsByID.keys), Set(loaded.songsByID.keys))
        for (id, song) in loaded.songsByID {
            XCTAssertEqual(released.songsByID[id], song, "cover song \(id)")
        }
        // 没预挑过的文件夹:按节点挑的与内存里同一条规则挑的相同。
        let picked = try XCTUnwrap(HomeFolderCoverPrewarm.picks(Array(expectedPicks.keys), in: catalogIndex, catalog: catalog) { false })
        XCTAssertEqual(picked.mapValues { $0.map(\.id) }, expectedPicks, "every folder's picks")

        // 卡片要画一个没预挑过的文件夹:这一刻先画图标(不在主线程上逐首读),后台挑好之后重画成同一组封面。
        let model = HomeDiscoveryModel()
        model.bindLibrary(library)
        model.publish(
            index: catalogIndex, songs: [:], covers: [:],
            request: HomeDiscoveryModel.Request(collection: 0, playlists: 0, hierarchy: 0, names: 0, sources: []),
            metadataToken: UUID(), directoryNames: [:]
        )
        let revision = model.revision
        XCTAssertTrue(model.coverSongs(for: bigNode).isEmpty, "nothing is read on the main thread")
        try await waitUntil("the queued pick", timeout: .seconds(15)) { model.revision != revision }
        XCTAssertEqual(model.coverSongs(for: bigNode).map(\.id), expectedPicks[bigNode])
        for id in expectedPicks.keys { _ = model.coverSongs(for: id) }
        try await waitUntil("every folder's queued pick", timeout: .seconds(15)) {
            expectedPicks.allSatisfy { model.folderCoverSongIDs[$0.key] != nil }
        }
        for (id, ids) in expectedPicks {
            XCTAssertEqual(model.coverSongs(for: id).map(\.id), ids, "card covers of \(id)")
        }
        assertNoLoadAndNoArrayRead(library, since: before, "folder covers while released")
    }
}
