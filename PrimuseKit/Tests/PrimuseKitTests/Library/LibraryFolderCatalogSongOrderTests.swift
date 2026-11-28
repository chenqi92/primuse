import Foundation
import Testing
@testable import PrimuseKit

/// 「目录」页的歌曲先后在曲库目录上排(`LibraryFolderCatalogSongOrder`,6c 单元 4 U9a):每个节点、页面列出的与整棵子树、
/// 「目录」页提供的每一种顺序,都与模型在内存里时按可见歌排的(`LibraryFolderBrowsePolicy.sortedSongs`)逐首相同 ——
/// 目录版与内存版分区(Apple Music 虚拟集合)、整夹有声(书架顺序)、建完之后删掉的行;要整首歌而超过上限时答 nil。
@Suite("Folder song order from the catalog", .serialized)
struct LibraryFolderCatalogSongOrderTests {
    static let orders: [HomeFolderSongOrder] = [
        .trackOrder, .originalName(ascending: true), .originalName(ascending: false),
        .sorted(.title), .sorted(.titleDescending), .sorted(.artist), .sorted(.artistDescending),
        .sorted(.album), .sorted(.albumDescending), .sorted(.dateAdded), .sorted(.dateAddedOldest),
        .sorted(.sourceDate), .sorted(.sourceDateOldest), .sorted(.format), .sorted(.formatDescending),
        .titleLanguageFirst(.englishFirst, ascending: true), .titleLanguageFirst(.chineseFirst, ascending: false),
    ]

    /// 给随机库的歌补上整首歌才有的列(艺人、专辑、加入时间、来源日期、格式),按这些排的顺序才有东西可比。
    static func decorated(_ songs: [Song], seed: UInt64) -> [Song] {
        var rng = CatalogTestRandom(seed: seed &* 7_919)
        return songs.map { song in
            var song = song
            song.albumTitle = rng.pick(["Blue", "blue", "Café", "Cafe\u{301}", "第一季", ""] as [String?] + [nil])
            song.albumID = song.albumTitle.map { "album-\($0)-\(rng.int(0...1))" }
            song.artistName = rng.pick(["Ada", "ada", "Ben", "周杰伦", ""] as [String?] + [nil])
            song.dateAdded = Date(timeIntervalSince1970: Double(rng.int(0...5)))
            song.lastModified = rng.maybe(70) { Date(timeIntervalSince1970: Double($0.int(0...4))) }
            song.fileFormat = rng.pick([.flac, .mp3, .m4a, .wav])
            return song
        }
    }

    /// 内存里那条路:页面列出的(或整棵子树的)id 在可见歌里查到的,交给同一个排序函数。
    static func memoryOrder(
        _ id: LibraryFolderNodeID, scope: LibraryFolderCatalogSongOrder.Scope, index: LibraryFolderIndex,
        order: HomeFolderSongOrder, spoken: Set<String>, songForID: (String) -> Song?
    ) -> [String] {
        let ids = scope == .displayed
            ? LibraryFolderBrowsePolicy.displayedSongIDs(in: index, of: id)
            : index.songIDs(in: id, scope: .descendants)
        return LibraryFolderBrowsePolicy.sortedSongs(ids.compactMap(songForID), order: order, spokenWordSongIDs: spoken).map(\.id)
    }

    /// 每个节点、两种范围、每种顺序都相同;返回比过的歌数。
    @discardableResult
    static func expectSameOrder(
        memory: LibraryFolderIndex, catalog: LibraryFolderIndex, store: LibraryCatalog, spoken: Set<String>,
        songForID: (String) -> Song?, _ label: String
    ) throws -> Int {
        var pending = memory.sourceNodeIDs
        var compared = 0
        while let id = pending.popLast() {
            for scope in [LibraryFolderSongScope.direct, .descendants] {
                #expect(
                    try LibraryFolderCatalogSongOrder.songIDs(in: id, scope: scope, index: catalog, catalog: store)
                        == catalog.songIDs(in: id, scope: scope),
                    "\(label): ids of \(id) \(scope)"
                )
            }
            for scope in [LibraryFolderCatalogSongOrder.Scope.displayed, .descendants] {
                for order in orders {
                    let expected = memoryOrder(id, scope: scope, index: memory, order: order, spoken: spoken, songForID: songForID)
                    let answered = try LibraryFolderCatalogSongOrder.ordered(
                        in: id, scope: scope, index: catalog, order: order, spokenWordSongIDs: spoken, catalog: store
                    )
                    #expect(answered?.ids == expected, "\(label): node \(id) \(scope) \(order)")
                    if let answered {
                        #expect(answered.rowids.count == answered.ids.count, "\(label): rowids \(id)")
                        #expect(try store.songIDs(rowids: answered.rowids) == answered.ids, "\(label): rowids line up \(id)")
                    }
                    compared += expected.count
                }
            }
            pending.append(contentsOf: memory.children(of: id).map(\.id))
        }
        return compared
    }

    @Test("Random libraries: every node, scope and order matches the in-memory sort", arguments: Array(UInt64(1)...UInt64(16)))
    func randomLibraries(seed: UInt64) throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: seed)
        library.songs = Self.decorated(library.songs, seed: seed)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let kinds = try LibraryFolderCatalogIndexTests.kinds(library.songs, in: temporary.catalog)
        let spoken = Set(kinds.filter { $0.value == .spokenWord || $0.value == .podcast }.keys)
        let byID = Dictionary(library.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let unlisted: (String) -> LibraryFolderSourceDescriptor? = { $0 == library.unlisted.sourceID ? library.unlisted : nil }
        for shelf in [false, true] {
            let spokenSet: Set<String> = shelf ? spoken : []
            let memory = LibraryFolderIndexBuilder.build(
                sources: LibraryFolderCatalogIndexTests.memoryDescriptors(library, songs: library.songs),
                songs: library.songs, spokenWordSongIDs: spokenSet
            )
            let built = try LibraryFolderIndexBuilder.build(
                sources: library.configured,
                catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: shelf),
                unlistedSource: unlisted
            )
            let compared = try Self.expectSameOrder(
                memory: memory, catalog: built, store: temporary.catalog, spoken: spokenSet,
                songForID: { byID[$0] }, "seed \(seed) shelf \(shelf)"
            )
            #expect(compared > 0, "seed \(seed): something was compared")
        }

        // 建完之后删掉的歌两边都不再排(内存那边同一时刻也不在可见歌里了)。
        let memory = LibraryFolderIndexBuilder.build(
            sources: LibraryFolderCatalogIndexTests.memoryDescriptors(library, songs: library.songs), songs: library.songs
        )
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            unlistedSource: unlisted
        )
        let removed = library.songs.filter { built.nodeID(containingSongID: $0.id) != nil }.prefix(4)
        try temporary.catalog.apply(upserts: [], deletingIDs: removed.map(\.id))
        let gone = Set(removed.map(\.id))
        try Self.expectSameOrder(
            memory: memory, catalog: built, store: temporary.catalog, spoken: [],
            songForID: { gone.contains($0) ? nil : byID[$0] }, "seed \(seed) after deletes"
        )
    }

    @Test("Orders that need whole songs answer nil past the limit; folder-column orders do not")
    func songLimit() throws {
        var library = LibraryFolderCatalogIndexTests.randomLibrary(seed: 3)
        library.songs = Self.decorated(library.songs, seed: 3)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false)
        )
        let root = try #require(built.sourceNodeIDs.first { (built.rowids(in: $0, scope: .descendants)?.count ?? 0) > 3 })
        for order in Self.orders {
            let answered = try LibraryFolderCatalogSongOrder.ordered(
                in: root, scope: .descendants, index: built, order: order, spokenWordSongIDs: [], catalog: temporary.catalog,
                songLimit: 3
            )
            #expect((answered == nil) == !LibraryFolderCatalogSongOrder.readsFolderColumnsOnly(order), "\(order)")
        }
        #expect(throws: CancellationError.self) {
            _ = try LibraryFolderCatalogSongOrder.ordered(
                in: root, scope: .descendants, index: built, order: .trackOrder, spokenWordSongIDs: [],
                catalog: temporary.catalog, isCancelled: { true }
            )
        }
    }

    @Test("Apple Music virtual collections (in-memory partition) order by id")
    func virtualCollections() throws {
        let appleMusic = "primuse.appleMusic.system"
        var songs = (0..<12).map { index in
            Song(id: "am\(index)", title: ["Zeta", "alpha", "第3集", "Beta"][index % 4], trackNumber: (index * 7) % 5,
                 duration: 1, fileFormat: .m4a, filePath: "am://\(index)", sourceID: appleMusic)
        }
        songs += (0..<6).map { index in
            Song(id: "nas\(index)", title: "NAS \(index)", trackNumber: 6 - index, duration: 1, fileFormat: .flac,
                 filePath: "/Music/Album/\(index).flac", sourceID: "smb")
        }
        songs = Self.decorated(songs, seed: 11)
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
        let compared = try Self.expectSameOrder(
            memory: memory, catalog: built, store: temporary.catalog, spoken: [], songForID: { byID[$0] }, "virtual"
        )
        #expect(compared > 0)
    }
}
