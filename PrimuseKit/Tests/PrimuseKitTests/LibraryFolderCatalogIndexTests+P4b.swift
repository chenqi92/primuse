import Foundation
import Testing
@testable import PrimuseKit

/// 按曲库目录建的文件夹索引必须与按整库 `[Song]` 建的那份逐项相同:节点、名字、计数、子节点顺序、
/// 每个节点里歌的先后、按 id 找节点、封面挑选、重新扫描锚点。
@Suite("Library folder index from the catalog", .serialized)
struct LibraryFolderCatalogIndexTests {
    static let directoryComponents = [
        "Music", "music", "MUSIC", "Classical", "Rock", "rock", "Café", "Cafe\u{301}", "A%20B", "A%2FB", "100%",
        "@eaDir", "#Tag", "Why?", "Caches", "cache", ".", "..", " Spaced ", "Library", "Live Sets", "Live%20Sets",
        "Volumes", "Share", "share", "Audio", "周杰伦", "第一季", "a:b", "C:", "tmp", "private", "var", "folders",
        "home", "Users", "1-50", "51-100", "101-150",
    ]
    static let fileNames = [
        "01 Song.flac", "02 Song.flac", "10 Song.flac", "2 Song.flac", "Live @ Home.flac", "100%.mp3", "A%2FB.mp3",
        "Why?.mp3", "#1.mp3", "a:b.mp3", "cache", "Caches", ".", "..", "folders", "tmp", " song.mp3", "song.mp3 ",
        "第1集.mp3", "第2集 改.mp3", "第10集.mp3", "A\\B.mp3", "Classical", "music", "x.flac", "song", "雨一直下.flac",
        "Cafe\u{301}.flac", "track\u{200B}.flac", "Live\n.flac", ".hidden.flac", "Disc 1.flac", "1-03 Title.flac",
        "Share", "Audio", "03 Song.flac", "03 Song.flac",
    ]
    static let titles = ["Intro", "第1集", "第2集", "第3集", "Song 1", "Song 2", "Song 10", "雨", "Apple", "apple", "", "1"]

    struct Library {
        var configured: [LibraryFolderSourceDescriptor]
        var unlisted: LibraryFolderSourceDescriptor
        var songs: [Song]
        var overrides: [String: ListeningContentKind]
    }

    static func randomLibrary(seed: UInt64) -> Library {
        var rng = CatalogTestRandom(seed: seed)
        func subset(_ values: [String]) -> [String] {
            let picked = values.filter { _ in rng.chance(45) }
            return picked.isEmpty ? [rng.pick(values)] : picked
        }
        let smb = LibraryFolderSourceDescriptor(
            sourceID: "smb", displayName: "NAS",
            scanRoots: subset(["/Music", "/Music/Classical", "/", "/Volumes/Share", "/music/rock", "Music/Live Sets"]),
            pathSemantics: .hierarchical, pathEncoding: .native
        )
        let nfs = LibraryFolderSourceDescriptor(
            sourceID: "nfs", displayName: "NFS",
            scanRoots: subset(["Music", "/share/Audio", "/", "Music/Live%20Sets", "/Users/me"]),
            pathSemantics: .hierarchical, pathEncoding: .legacyNormalized
        )
        let server = LibraryFolderSourceDescriptor(
            sourceID: "srv", displayName: "Server", scanRoots: [], pathSemantics: .opaque
        )
        let noRoots = LibraryFolderSourceDescriptor(
            sourceID: "bare", displayName: "Bare", scanRoots: [], pathSemantics: .hierarchical, pathEncoding: .native
        )
        let off = LibraryFolderSourceDescriptor(
            sourceID: "off", displayName: "Off", scanRoots: ["/"], pathSemantics: .hierarchical, isEnabled: false
        )
        // 网盘:服务端给的目录层级,歌的路径是条目 id。
        var items: [LibraryFolderProviderItemDescriptor] = []
        let folders = (1...6).map { "fold-\($0)" }
        for (index, folder) in folders.enumerated() {
            let parent = index == 0 ? "root-a" : rng.pick(["root-a", "root-b", folders[max(0, index - 1)], "missing"])
            items.append(LibraryFolderProviderItemDescriptor(
                path: folder, displayName: rng.pick(["Disc 1", "Disc 2", "第一季", "1-50", "51-100", "Live"]),
                parentPath: parent, isDirectory: true
            ))
        }
        for index in 0..<40 {
            items.append(LibraryFolderProviderItemDescriptor(
                path: "file-\(index)", displayName: rng.pick(fileNames),
                parentPath: rng.maybe(90) { $0.pick(folders + ["root-a", "root-b", "missing"]) }, isDirectory: false
            ))
        }
        let drive = LibraryFolderSourceDescriptor(
            sourceID: "drive", displayName: "Drive", scanRoots: [], pathSemantics: .opaque,
            providerHierarchy: LibraryFolderProviderHierarchy(
                roots: [
                    LibraryFolderProviderRootDescriptor(path: "root-a", displayName: "Disk A"),
                    LibraryFolderProviderRootDescriptor(path: "root-b", displayName: nil),
                ],
                items: items
            )
        )
        let unlisted = LibraryFolderSourceDescriptor(
            sourceID: "extra", displayName: "Extra", scanRoots: [], pathSemantics: .opaque
        )

        func hierarchicalPath() -> String {
            if rng.chance(3) { return "" }
            var components: [String] = []
            for _ in 0..<rng.int(0...4) { components.append(rng.pick(directoryComponents)) }
            components.append(rng.pick(fileNames))
            var path = components.joined(separator: rng.chance(4) ? "//" : "/")
            if rng.chance(60) { path = "/" + path }
            if rng.chance(3) { path += "/" }
            if rng.chance(3) { path = " " + path }
            return path
        }

        var songs: [Song] = []
        var overrides: [String: ListeningContentKind] = [:]
        for index in 0..<rng.int(40...220) {
            let sourceID = rng.pick(["smb", "smb", "smb", "nfs", "nfs", "srv", "drive", "bare", "off", "extra", "ghost"])
            let path: String
            switch sourceID {
            case "drive": path = rng.chance(85) ? "file-\(rng.int(0...44))" : "/odd/\(index).flac"
            case "srv": path = rng.pick(["/songs/\(index)", "https://host/stream/\(index).mp3", "", "Music/a.flac"])
            default: path = hierarchicalPath()
            }
            let id = "s\(index)"
            songs.append(Song(
                id: id,
                title: rng.pick(titles),
                trackNumber: rng.maybe(60) { $0.pick([0, 1, 1, 2, 3, 10, -1]) },
                discNumber: rng.maybe(30) { $0.pick([0, 1, 2]) },
                duration: 180,
                fileFormat: .flac,
                filePath: path,
                sourceID: sourceID,
                dateAdded: Date(timeIntervalSince1970: Double(index))
            ))
            if rng.chance(15) { overrides[id] = rng.pick([ListeningContentKind.spokenWord, .podcast, .spokenWord]) }
        }
        // 整文件夹的有声:同一目录下好几首都标成有声,书架顺序那条路径才走得到。
        if let book = songs.first(where: { $0.sourceID == "smb" && !$0.filePath.isEmpty }) {
            for index in 0..<4 {
                let id = "book\(index)"
                let directory = AlbumArtistInferencePolicy.directory(ofPath: book.filePath)
                songs.append(Song(
                    id: id, title: "第\(4 - index)集", trackNumber: rng.maybe(50) { _ in 1 }, duration: 600,
                    fileFormat: .m4a, filePath: "\(directory)/第\(4 - index)集.m4a", sourceID: "smb",
                    dateAdded: Date(timeIntervalSince1970: 0)
                ))
                overrides[id] = .spokenWord
            }
        }
        return Library(
            configured: [smb, nfs, server, noRoots, off, drive],
            unlisted: unlisted,
            songs: songs,
            overrides: overrides
        )
    }

    /// 首页的做法:目录里有、配置里没有的源按第一次出现的先后补一个描述。
    static func memoryDescriptors(_ library: Library, songs: [Song]) -> [LibraryFolderSourceDescriptor] {
        var descriptors = library.configured
        var known = Set(descriptors.map(\.sourceID))
        for song in songs where known.insert(song.sourceID).inserted {
            if song.sourceID == library.unlisted.sourceID { descriptors.append(library.unlisted) }
        }
        return descriptors
    }

    static func makeCatalog(_ library: Library) throws -> TemporaryCatalog {
        let temporary = try TemporaryCatalog()
        try temporary.catalog.setGroupingConfiguration(LibraryGroupingConfiguration(
            classification: SpokenWordClassificationInputs(overrides: library.overrides)
        ))
        try temporary.catalog.apply(upserts: library.songs)
        return temporary
    }

    static func kinds(_ songs: [Song], in catalog: LibraryCatalog) throws -> [String: LibraryCatalogContentKind] {
        var result: [String: LibraryCatalogContentKind] = [:]
        for song in songs { result[song.id] = try catalog.contentKind(songID: song.id) }
        return result
    }

    static func expectSame(
        _ memory: LibraryFolderIndex,
        _ catalog: LibraryFolderIndex,
        songs: [Song],
        seed: UInt64,
        _ label: String
    ) {
        let context = "seed \(seed) \(label)"
        #expect(memory.sourceNodeIDs == catalog.sourceNodeIDs, "\(context): sources")
        #expect(memory.songCount == catalog.songCount, "\(context): songCount")
        #expect(memory.nodeCount == catalog.nodeCount, "\(context): nodeCount")
        var pending = memory.sourceNodeIDs
        var nodes = 0
        while let id = pending.popLast() {
            nodes += 1
            #expect(memory.node(withID: id) == catalog.node(withID: id), "\(context): node \(id)")
            let children = memory.children(of: id)
            #expect(children == catalog.children(of: id), "\(context): children \(id)")
            #expect(memory.directSongIDs(in: id) == catalog.directSongIDs(in: id), "\(context): direct \(id)")
            let descendants = memory.songIDs(in: id, scope: .descendants)
            #expect(descendants == catalog.songIDs(in: id, scope: .descendants), "\(context): descendants \(id)")
            #expect(memory.songIDs(in: id, scope: .direct) == catalog.songIDs(in: id, scope: .direct), "\(context): scoped direct \(id)")
            let picks: (String) -> Bool = { $0.hashValue & 1 == 0 || $0.hasSuffix("3") }
            #expect(
                memory.firstSongIDs(in: id, limit: 4, where: picks) == catalog.firstSongIDs(in: id, limit: 4, where: picks),
                "\(context): covers \(id)"
            )
            #expect(
                LibraryFolderRescanAnchor.make(for: id, in: memory) == LibraryFolderRescanAnchor.make(for: id, in: catalog),
                "\(context): anchor \(id)"
            )
            #expect(
                LibraryFolderBrowsePolicy.displayedChildren(in: memory, of: id)
                    == LibraryFolderBrowsePolicy.displayedChildren(in: catalog, of: id),
                "\(context): displayed children \(id)"
            )
            #expect(
                LibraryFolderBrowsePolicy.displayedSongIDs(in: memory, of: id)
                    == LibraryFolderBrowsePolicy.displayedSongIDs(in: catalog, of: id),
                "\(context): displayed songs \(id)"
            )
            if catalog.isCatalogBacked(sourceID: id.sourceID), let rowids = catalog.rowids(in: id, scope: .descendants) {
                #expect(rowids.count == descendants.count, "\(context): rowids \(id)")
            }
            pending.append(contentsOf: children.map(\.id))
        }
        #expect(nodes == memory.nodeCount, "\(context): every node reached")
        let ids = songs.map(\.id) + ["missing-id"]
        var expected: [String: LibraryFolderNodeID] = [:]
        for id in ids {
            let node = memory.nodeID(containingSongID: id)
            #expect(node == catalog.nodeID(containingSongID: id), "\(context): node of \(id)")
            if let node { expected[id] = node }
            #expect(
                LibraryFolderBrowsePolicy.displayedNodeID(containingSongID: id, in: memory)
                    == LibraryFolderBrowsePolicy.displayedNodeID(containingSongID: id, in: catalog),
                "\(context): displayed node of \(id)"
            )
        }
        #expect(catalog.nodeIDs(containingSongIDs: ids) == expected, "\(context): batch lookup")
        #expect(memory.nodeIDs(containingSongIDs: ids) == expected, "\(context): memory batch lookup")
    }

    @Test("Random libraries: every scope and ordering matches the in-memory index", arguments: Array(UInt64(1)...UInt64(40)))
    func randomLibrariesMatch(seed: UInt64) throws {
        let library = Self.randomLibrary(seed: seed)
        let temporary = try Self.makeCatalog(library)
        let catalog = temporary.catalog
        let kinds = try Self.kinds(library.songs, in: catalog)
        let spoken = Set(kinds.filter { $0.value == .spokenWord || $0.value == .podcast }.keys)
        let unlisted: (String) -> LibraryFolderSourceDescriptor? = { $0 == library.unlisted.sourceID ? library.unlisted : nil }

        // 全部可见的歌,不按书架读。
        let memoryAll = LibraryFolderIndexBuilder.build(
            sources: Self.memoryDescriptors(library, songs: library.songs), songs: library.songs
        )
        let catalogAll = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            unlistedSource: unlisted
        )
        Self.expectSame(memoryAll, catalogAll, songs: library.songs, seed: seed, "all")

        // 首页、车机、电视:有声的文件夹照书架读。
        let memoryShelf = LibraryFolderIndexBuilder.build(
            sources: Self.memoryDescriptors(library, songs: library.songs), songs: library.songs, spokenWordSongIDs: spoken
        )
        let catalogShelf = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: true),
            unlistedSource: unlisted
        )
        Self.expectSame(memoryShelf, catalogShelf, songs: library.songs, seed: seed, "shelf")

        // 歌曲页、搜索:只要音乐。
        let music = library.songs.filter { kinds[$0.id] == .music }
        let memoryMusic = LibraryFolderIndexBuilder.build(sources: Self.memoryDescriptors(library, songs: music), songs: music)
        let catalogMusic = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: [.music], ordersSpokenWordLikeShelf: false),
            unlistedSource: unlisted
        )
        Self.expectSame(memoryMusic, catalogMusic, songs: library.songs, seed: seed, "music")
        #expect(catalogMusic.isCatalogBacked(sourceID: "smb") || catalogMusic.sourceNode(for: "smb") == nil)
    }

    @Test("Disabled catalog sources and songs added after the build stay out")
    func disabledSourcesAndLaterSongs() throws {
        let library = Self.randomLibrary(seed: 99)
        let temporary = try Self.makeCatalog(library)
        let catalog = temporary.catalog
        try catalog.setSourceEnabled(false, sourceID: "nfs")
        let visible = library.songs.filter { $0.sourceID != "nfs" }
        let memory = LibraryFolderIndexBuilder.build(sources: Self.memoryDescriptors(library, songs: visible), songs: visible)
        let built = try LibraryFolderIndexBuilder.build(
            sources: library.configured,
            catalog: LibraryFolderCatalogInput(catalog: catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            unlistedSource: { $0 == "extra" ? library.unlisted : nil }
        )
        Self.expectSame(memory, built, songs: library.songs, seed: 99, "disabled nfs")

        // 建完之后加进来的歌不在这份索引里(与内存版一样,要等重建)。
        let late = Song(id: "late", title: "Late", duration: 1, fileFormat: .flac, filePath: "/Music/late.flac", sourceID: "smb")
        try catalog.apply(upserts: [late])
        #expect(built.nodeID(containingSongID: "late") == nil)
        // 删掉的歌按行号取 id 时被跳过。
        let removed = library.songs.first { $0.sourceID == "smb" && built.nodeID(containingSongID: $0.id) != nil }
        if let removed, let node = built.nodeID(containingSongID: removed.id) {
            try catalog.apply(upserts: [], deletingIDs: [removed.id])
            #expect(!built.directSongIDs(in: node).contains(removed.id))
            #expect(built.nodeID(containingSongID: removed.id) == nil)
        }
    }

    @Test("Apple Music virtual collections keep the in-memory partition")
    func virtualCollectionsStayInMemory() throws {
        let appleMusic = "primuse.appleMusic.system"
        var songs = (0..<12).map { index in
            Song(id: "am\(index)", title: "AM \(index)", duration: 1, fileFormat: .m4a,
                 filePath: "am://\(index)", sourceID: appleMusic)
        }
        songs += (0..<6).map { index in
            Song(id: "nas\(index)", title: "NAS \(index)", trackNumber: 6 - index, duration: 1, fileFormat: .flac,
                 filePath: "/Music/Album/\(index).flac", sourceID: "smb")
        }
        let descriptors = [
            LibraryFolderSourceDescriptor(sourceID: "smb", displayName: "NAS", scanRoots: ["/Music"],
                                          pathSemantics: .hierarchical, pathEncoding: .native),
            LibraryFolderSourceDescriptor(sourceID: appleMusic, displayName: "Apple Music", scanRoots: [],
                                          pathSemantics: .opaque),
        ]
        let collections = [
            LibraryFolderVirtualCollectionDescriptor(sourceID: appleMusic, identity: "library", displayName: "Songs",
                                                     kind: .librarySongs, songIDs: ["am3", "am1"]),
            LibraryFolderVirtualCollectionDescriptor(sourceID: appleMusic, identity: "p1", displayName: "Mix",
                                                     kind: .playlist, songIDs: ["am5", "am2", "gone"]),
        ]
        let temporary = try TemporaryCatalog()
        try temporary.catalog.apply(upserts: songs)
        let memory = LibraryFolderIndexBuilder.build(sources: descriptors, songs: songs, virtualCollections: collections)
        let built = try LibraryFolderIndexBuilder.build(
            sources: descriptors,
            catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
            memorySongs: songs.filter { $0.sourceID == appleMusic },
            virtualCollections: collections
        )
        Self.expectSame(memory, built, songs: songs, seed: 0, "virtual")
        #expect(!built.isCatalogBacked(sourceID: appleMusic))
        #expect(built.isCatalogBacked(sourceID: "smb"))
    }

    @Test("Cancellation stops the build")
    func cancellationStops() throws {
        let library = Self.randomLibrary(seed: 7)
        let temporary = try Self.makeCatalog(library)
        #expect(throws: CancellationError.self) {
            try LibraryFolderIndexBuilder.build(
                sources: library.configured,
                catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false),
                isCancelled: { true }
            )
        }
    }

    @Test("Plain file names never change a folder placement", arguments: Array(UInt64(1)...UInt64(30)))
    func plainNamesMatchExactPlacement(seed: UInt64) {
        var rng = CatalogTestRandom(seed: seed &* 7_919)
        for encoding in [LibraryFolderPathEncoding.native, .legacyNormalized] {
            let roots = (0..<rng.int(1...3)).map { _ in
                rng.pick(["/", "/Music", "Music", "/Music/Classical", "/Volumes/Share", "music/rock", "/Users/me", "Library"])
            }
            let policy = LibraryFolderPathPolicy(scanRoots: roots, encoding: encoding)
            let rule = LibraryFolderPlainFileNameRule(policy: policy)
            for _ in 0..<400 {
                var components: [String] = []
                for _ in 0..<rng.int(1...4) { components.append(rng.pick(Self.directoryComponents)) }
                let directory = (rng.chance(50) ? "/" : "") + components.joined(separator: "/")
                let first = directory + "/" + rng.pick(Self.fileNames)
                let second = directory + "/" + rng.pick(Self.fileNames)
                guard rule.isPlain(first), rule.isPlain(second) else { continue }
                #expect(
                    policy.nodeID(sourceID: "s", for: first) == policy.nodeID(sourceID: "s", for: second),
                    "seed \(seed) \(encoding) roots \(roots): \(first) vs \(second)"
                )
            }
        }
    }
}
