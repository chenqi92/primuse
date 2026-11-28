import Foundation
import Testing
@testable import PrimuseKit

/// `songIDs(_:inScope:)`(6c 单元 4 U9a,歌曲页模型不在内存里时修剪多选):给出的 id 里此刻在范围内的,与按同一范围
/// 读出整首歌再挑的相同 —— 类别、单个源、停用的源、删掉的行、不在目录里的 id。
@Suite("Catalog scope membership")
struct LibraryCatalogScopeMembershipTests {
    @Test("The ids in a scope equal the songs the same scope materializes", arguments: Array(UInt64(1)...UInt64(6)))
    func matchesMaterializedScope(seed: UInt64) throws {
        let library = LibraryFolderCatalogIndexTests.randomLibrary(seed: seed)
        let temporary = try LibraryFolderCatalogIndexTests.makeCatalog(library)
        let catalog = temporary.catalog
        try catalog.setSourceEnabled(false, sourceID: "nfs")
        let deleted = Array(library.songs.prefix(3).map(\.id))
        try catalog.apply(upserts: [], deletingIDs: deleted)
        let asked = library.songs.map(\.id) + ["no-such-song"]
        let scopes = [
            LibrarySongScope.visible, .visibleMusic, .everything,
            LibrarySongScope(kinds: [.music, .collectionOnly], sourceID: "smb"),
            LibrarySongScope(kinds: [.spokenWord, .podcast]),
            LibrarySongScope(sourceID: "nfs"),
        ]
        for scope in scopes {
            var expected = Set<String>()
            var start = 0
            while start < asked.count {
                let end = min(asked.count, start + LibraryScale.maxMaterializedRows)
                expected.formUnion(try catalog.songs(ids: Array(asked[start..<end]), scope: scope).map(\.id))
                start = end
            }
            #expect(try catalog.songIDs(asked, inScope: scope) == expected, "seed \(seed) scope \(scope)")
            #expect(try catalog.songIDs(asked, inScope: scope).isDisjoint(with: deleted))
        }
        #expect(try catalog.songIDs([String](), inScope: .visible).isEmpty)
    }
}
