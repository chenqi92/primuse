import Foundation
import PrimuseKit
import XCTest
@testable import Primuse

/// 6c 单元 4 U6b:目录页(首页目录区、目录管理页、歌曲页的目录版式、资料库首页的目录收藏)要的目录索引在歌曲模型放掉之后
/// 按曲库目录建,与模型在内存里时按整库数组建的那份逐个节点相同;统计页的歌曲特征表放掉之后从目录取,与内存里的相同。
/// 都不装模型、不读整库数组。
@MainActor
final class LibraryPagesU6bReleasedTests: LibraryReleasedTwinTestCase {
    func testFolderIndexBuildsFromTheCatalogWhileReleasedLikeTheLoadedOne() async throws {
        let prefix = "u6b-folders"
        let (library, _) = try makeLaunchedTwin(prefix, songs: Self.fixture(prefix: prefix))
        await assertShadowMatches(library, "fixture")
        let appleMusicName = String(localized: "apple_music_library_section")
        let sourceName = String(localized: "source_label")
        // 首页的内存路径:配置里没有的源按歌出现的先后补描述(同 `LibraryFolderUnlistedSource`)。
        let songs = library.visibleSongs
        var descriptors: [LibraryFolderSourceDescriptor] = []
        var known = Set<String>()
        for song in songs where known.insert(song.sourceID).inserted {
            descriptors.append(LibraryFolderUnlistedSource.descriptor(
                sourceID: song.sourceID, appleMusicName: appleMusicName, genericName: sourceName
            ))
        }
        let spokenWordSongIDs = library.spokenWordSongIDs
        let snapshot = library.appleMusicFolderSnapshot()
        let memory = LibraryFolderIndexBuilder.build(
            sources: descriptors, songs: songs,
            virtualCollections: snapshot.collections(availableSongs: songs), spokenWordSongIDs: spokenWordSongIDs
        )
        XCTAssertGreaterThan(memory.nodeCount, 1)

        let before = try await releaseForReal(library)
        let reader = try XCTUnwrap(library.readableCatalogReader)
        // 首页模型不在内存里时那条路:Apple Music 虚拟集合那个源的歌从目录取,其余按目录建。
        let answered = await LibraryFolderCatalogSongs.appleMusicSongs(snapshot, scope: .visible, reader: reader)
        let collectionSongs = try XCTUnwrap(answered, "a readable catalog answers")
        // 目录读不了时答不出来(nil),不当成没有歌。
        let unanswered = await LibraryFolderCatalogSongs.appleMusicSongs(snapshot, scope: .visible, reader: nil)
        XCTAssertEqual(unanswered == nil, snapshot.enabled, "no reader: nil when the collections are on")
        let collections = snapshot.collections(availableSongs: collectionSongs)
        let catalog = try await reader.folderIndex { catalog, isCancelled in
            try LibraryFolderIndexBuilder.build(
                sources: [],
                catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: !spokenWordSongIDs.isEmpty),
                unlistedSource: { sourceID in
                    LibraryFolderUnlistedSource.descriptor(sourceID: sourceID, appleMusicName: appleMusicName, genericName: sourceName)
                },
                memorySongs: collectionSongs,
                virtualCollections: collections,
                spokenWordSongIDs: spokenWordSongIDs,
                isCancelled: isCancelled
            )
        }
        XCTAssertEqual(catalog.sourceNodeIDs, memory.sourceNodeIDs, "sources")
        XCTAssertEqual(catalog.nodeCount, memory.nodeCount, "node count")
        XCTAssertEqual(catalog.songCount, memory.songCount, "song count")
        var pending = memory.sourceNodeIDs
        while let id = pending.popLast() {
            XCTAssertEqual(catalog.node(withID: id), memory.node(withID: id), "node \(id)")
            XCTAssertEqual(catalog.children(of: id), memory.children(of: id), "children \(id)")
            XCTAssertEqual(catalog.songIDs(in: id, scope: .descendants), memory.songIDs(in: id, scope: .descendants), "songs \(id)")
            XCTAssertEqual(
                LibraryFolderBrowsePolicy.displayedChildren(in: catalog, of: id).map(\.id),
                LibraryFolderBrowsePolicy.displayedChildren(in: memory, of: id).map(\.id),
                "displayed order \(id)"
            )
            pending.append(contentsOf: memory.children(of: id).map(\.id))
        }
        assertNoLoadAndNoArrayRead(library, since: before, "folder index while released")
    }

    func testStatisticsSongTraitsAnswerFromTheCatalogWhileReleased() async throws {
        let prefix = "u6b-stats"
        let songs = Self.fixture(prefix: prefix)
        let (library, _) = try makeLaunchedTwin(prefix, songs: songs)
        await assertShadowMatches(library, "fixture")
        let entries = songs.prefix(8).enumerated().map { offset, song in
            PlayHistoryStore.Entry(
                songID: song.id, songTitle: song.title, artistName: song.artistName ?? "", albumTitle: song.albumTitle ?? "",
                playedAt: Date(timeIntervalSince1970: 1_750_000_000 + Double(offset) * 600), listenedSec: 120,
                sourceID: song.sourceID
            )
        }
        let loaded = YearlyReportAnalyzer.songTraits(for: entries, library: library, resolvedCandidates: [:])
        XCTAssertFalse(loaded.isEmpty)

        let before = try await releaseForReal(library)
        let released = await ListeningStatsView.catalogSongTraits(for: entries, library: library)
        XCTAssertEqual(released, loaded, "the same traits (genre, album, artist, year …) for every played song")
        assertNoLoadAndNoArrayRead(library, since: before, "statistics traits while released")
    }
}
