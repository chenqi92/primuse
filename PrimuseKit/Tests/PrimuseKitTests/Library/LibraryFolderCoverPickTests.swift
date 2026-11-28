import Foundation
import Testing
@testable import PrimuseKit

/// 文件夹卡片在歌曲模型不在内存里时从曲库目录挑封面(`firstSongIDsWithCover`,6c 单元 4 U3c):每个节点、每个上限挑出的
/// 与按内存里的歌挑出的(`firstSongIDs(where: coverArtFileName != nil)`,模型在内存里时首页的预挑)逐个相同 ——
/// 目录版与内存版分区(Apple Music 虚拟集合)、空串与含 NUL 的封面名、建完之后删掉的行。
@Suite("Folder cover picks from the catalog", .serialized)
struct LibraryFolderCoverPickTests {
    /// 随机给一部分歌封面:普通的、空串(算有)、含 NUL 的(列里存替换过的串)。
    static func covered(_ songs: [Song], seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed &* 104_729)
        return songs.map { song in
            var song = song
            song.coverArtFileName = rng.chance(30) ? rng.pick(["cover.jpg", "", "a\u{0}b.jpg", "folder.png"]) : nil
            return song
        }
    }

    static func expectSamePicks(
        memory: LibraryFolderIndex, catalog: LibraryFolderIndex, store: LibraryCatalog,
        hasCover: (String) -> Bool, _ label: String
    ) throws -> Int {
        var pending = memory.sourceNodeIDs
        var picked = 0
        while let id = pending.popLast() {
            for limit in [1, 4, 40] {
                let expected = memory.firstSongIDs(in: id, limit: limit, where: hasCover)
                let answered = try catalog.firstSongIDsWithCover(in: id, limit: limit, catalog: store)
                #expect(answered == expected, "\(label): node \(id) limit \(limit)")
                picked += answered.count
            }
            pending.append(contentsOf: memory.children(of: id).map(\.id))
        }
        return picked
    }

    @Test("Random libraries: every node picks the same covers as the in-memory songs", arguments: Array(UInt64(1)...UInt64(20)))
    func randomLibraries(seed: UInt64) throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: seed)
        library.songs = Self.covered(library.songs, seed: seed)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let byID = Dictionary(library.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let memory = LibraryFolderIndexBuilder.build(
            sources: LibraryFolderCatalogIndexTests.memoryDescriptors(library, songs: library.songs), songs: library.songs
        )
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            unlistedSource: { $0 == library.unlisted.sourceID ? library.unlisted : nil }
        )
        let picked = try Self.expectSamePicks(
            memory: memory, catalog: built, store: temporary.catalog,
            hasCover: { byID[$0]?.coverArtFileName != nil }, "seed \(seed)"
        )
        #expect(picked > 0 || !library.songs.contains { $0.coverArtFileName != nil }, "seed \(seed): something was picked")

        // 建完之后删掉的歌不再挑(内存那边同一时刻也不在可见歌里了)。
        let removed = library.songs.filter { $0.coverArtFileName != nil && built.nodeID(containingSongID: $0.id) != nil }.prefix(3)
        try temporary.catalog.apply(upserts: [], deletingIDs: removed.map(\.id))
        let gone = Set(removed.map(\.id))
        _ = try Self.expectSamePicks(
            memory: memory, catalog: built, store: temporary.catalog,
            hasCover: { !gone.contains($0) && byID[$0]?.coverArtFileName != nil }, "seed \(seed) after deletes"
        )
    }

    @Test("Apple Music virtual collections (in-memory partition) pick by id")
    func virtualCollections() throws {
        let appleMusic = "primuse.appleMusic.system"
        var songs = (0..<12).map { index in
            Song(id: "am\(index)", title: "AM \(index)", duration: 1, fileFormat: .m4a, filePath: "am://\(index)",
                 sourceID: appleMusic, coverArtFileName: index.isMultiple(of: 3) ? "am\(index).jpg" : nil)
        }
        songs += (0..<6).map { index in
            Song(id: "nas\(index)", title: "NAS \(index)", trackNumber: 6 - index, duration: 1, fileFormat: .flac,
                 filePath: "/Music/Album/\(index).flac", sourceID: "smb", coverArtFileName: index == 4 ? "nas.jpg" : nil)
        }
        let descriptors = [
            LibraryFolderSourceDescriptor(sourceID: "smb", displayName: "NAS", scanRoots: ["/Music"],
                                          pathSemantics: .hierarchical, pathEncoding: .native),
            LibraryFolderSourceDescriptor(sourceID: appleMusic, displayName: "Apple Music", scanRoots: [], pathSemantics: .opaque),
        ]
        let collections = [
            LibraryFolderVirtualCollectionDescriptor(sourceID: appleMusic, identity: "library", displayName: "Songs",
                                                     kind: .librarySongs, songIDs: ["am3", "am1", "am6", "am9", "am0", "am2"]),
            LibraryFolderVirtualCollectionDescriptor(sourceID: appleMusic, identity: "p1", displayName: "Mix",
                                                     kind: .playlist, songIDs: ["am5", "am2", "gone", "am3"]),
        ]
        let temporary = try TemporaryCatalog()
        try temporary.catalog.apply(upserts: songs)
        let byID = Dictionary(songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let memory = LibraryFolderIndexBuilder.build(sources: descriptors, songs: songs, virtualCollections: collections)
        let built = try LibraryFolderIndexBuilder.build(
            sources: descriptors,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            memorySongs: songs.filter { $0.sourceID == appleMusic },
            virtualCollections: collections
        )
        #expect(!built.isCatalogBacked(sourceID: appleMusic))
        let picked = try Self.expectSamePicks(
            memory: memory, catalog: built, store: temporary.catalog, hasCover: { byID[$0]?.coverArtFileName != nil }, "virtual"
        )
        #expect(picked > 0)
    }

    @Test("A cancelled pick stops early")
    func cancellation() throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: 5)
        library.songs = Self.covered(library.songs, seed: 5)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false)
        )
        for id in built.sourceNodeIDs {
            #expect(try built.firstSongIDsWithCover(in: id, limit: 4, catalog: temporary.catalog, isCancelled: { true }).isEmpty)
        }
    }
}
