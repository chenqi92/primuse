import Darwin
import Foundation
import Testing
@testable import PrimuseKit

/// 文件夹索引常驻内存:按目录建(每首 4 字节行号)与按整库 `[Song]` 建(id 数组 + id → 节点字典)对比。
/// 默认 2 万首;`PRIMUSE_FOLDER_SCALE_SONGS` 可改。只量留下的那份索引,不量建的过程。
@Suite("Library folder index memory at scale", .serialized)
struct LibraryFolderCatalogScaleTests: LibraryScaleProbes {
    static var songCount: Int {
        ProcessInfo.processInfo.environment["PRIMUSE_FOLDER_SCALE_SONGS"].flatMap(Int.init) ?? 20_000
    }

    /// 建好后留下的字节数。量之前放掉目录各连接的页缓存,只量索引本身。
    static func retainedBytes<T>(catalog: LibraryCatalog, _ build: () throws -> T) rethrows -> (value: T, bytes: Int64) {
        catalog.releaseMemory()
        let before = Self.mallocBytes().inUse
        let value = try build()
        catalog.releaseMemory()
        let after = Self.mallocBytes().inUse
        return (value, Int64(after) - Int64(before))
    }

    @Test("A catalog-backed folder index keeps no per-song ids")
    func catalogIndexIsSmaller() throws {
        let library = LibraryCatalogSyntheticLibrary(songCount: Self.songCount)
        let temporary = try TemporaryCatalog()
        var songs: [Song] = []
        songs.reserveCapacity(library.songCount)
        for start in stride(from: 0, to: library.songCount, by: LibraryScale.importBatchSize) {
            let batch = (start..<min(start + LibraryScale.importBatchSize, library.songCount)).map(library.song(at:))
            try temporary.catalog.apply(upserts: batch)
            songs += batch
        }
        let sources = LibraryCatalogSyntheticLibrary.sources.map { sourceID in
            LibraryFolderSourceDescriptor(
                sourceID: sourceID, displayName: sourceID, scanRoots: ["Volumes/share/Music", "Audio"],
                pathSemantics: sourceID == "navidrome" ? .opaque : .hierarchical, pathEncoding: .native
            )
        }

        let memoryStart = Self.now()
        let memory = Self.retainedBytes(catalog: temporary.catalog) {
            LibraryFolderIndexBuilder.build(sources: sources, songs: songs)
        }
        let memorySeconds = Self.now() - memoryStart
        let catalogStart = Self.now()
        let catalog = try Self.retainedBytes(catalog: temporary.catalog) {
            try LibraryFolderIndexBuilder.build(
                sources: sources,
                catalog: LibraryFolderCatalogInput(catalog: temporary.catalog, kinds: nil, ordersSpokenWordLikeShelf: false)
            )
        }
        let catalogSeconds = Self.now() - catalogStart

        #expect(memory.value.songCount == catalog.value.songCount)
        #expect(memory.value.nodeCount == catalog.value.nodeCount)
        #expect(memory.value.sourceNodeIDs == catalog.value.sourceNodeIDs)
        for root in memory.value.sourceNodes {
            #expect(memory.value.node(withID: root.id) == catalog.value.node(withID: root.id))
        }
        let sample = songs[songs.count / 2].id
        #expect(memory.value.nodeID(containingSongID: sample) == catalog.value.nodeID(containingSongID: sample))

        // 两份的节点表一样大;差的就是每首歌的那部分(id 数组与 id → 节点表 对 4 字节行号)。
        let perSongSaving = Double(memory.bytes - catalog.bytes) / Double(library.songCount)
        print(String(
            format: "📁 folder index %d songs, %d nodes: memory %.1f MiB (%.0f B/song, %.2f s), catalog %.1f MiB (%.0f B/song, %.2f s), per-song saving %.0f B, catalog per node %.0f B",
            library.songCount, memory.value.nodeCount,
            Double(memory.bytes) / 1_048_576, Double(memory.bytes) / Double(library.songCount), memorySeconds,
            Double(catalog.bytes) / 1_048_576, Double(catalog.bytes) / Double(library.songCount), catalogSeconds,
            perSongSaving, Double(catalog.bytes - Int64(library.songCount * 4)) / Double(max(1, catalog.value.nodeCount))
        ))
        // 歌曲 id 在测试里与 `songs` 共用存储(App 里与内存曲库共用),这里只量得到表本身:每首至少省 60 字节。
        #expect(perSongSaving >= 60)
        withExtendedLifetime((memory.value, catalog.value)) {}
    }
}
