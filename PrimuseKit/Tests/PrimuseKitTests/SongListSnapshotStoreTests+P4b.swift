import Foundation
import Testing
@testable import PrimuseKit

/// 目录供列表时,快照仓库不再常驻超出小预算的整库快照,换成目录列表的那一页的快照随即放掉。
@Suite("Song list snapshot store with a catalog")
struct SongListSnapshotStoreCatalogTests {
    private func songs(_ count: Int, prefix: String) -> [Song] {
        (0..<count).map { index in
            Song(id: "\(prefix)\(index)", title: "Title \(count - index)", duration: 1, fileFormat: .flac,
                 filePath: "/m/\(prefix)\(index).flac", sourceID: "s")
        }
    }

    @Test("An oversized latest snapshot stays only while the catalog does not serve lists")
    func oversizedLatestIsDroppedWhenTheCatalogServes() async {
        let store = SongListSnapshotStore(maximumCachedRows: 10)
        let version = SongListSnapshotVersion(collectionRevision: 1, replacementToken: UUID())
        let large = songs(15, prefix: "l")
        let built = await store.snapshot(scopeKey: "library", version: version, order: .title, songs: large)
        #expect(built?.rows.count == 15)
        #expect(store.cachedSnapshot(scopeKey: "library", version: version, order: .title) != nil)

        await store.setCatalogServesLists(true)
        #expect(store.cachedSnapshot(scopeKey: "library", version: version, order: .title) == nil)
        let again = await store.snapshot(scopeKey: "library", version: version, order: .title, songs: large)
        #expect(again?.orderedSongIDs == built?.orderedSongIDs)
        #expect(store.cachedSnapshot(scopeKey: "library", version: version, order: .title) == nil)

        let small = songs(5, prefix: "s")
        _ = await store.snapshot(scopeKey: "source:s", version: version, order: .title, songs: small)
        #expect(store.cachedSnapshot(scopeKey: "source:s", version: version, order: .title) != nil)
        await store.releaseCachedSnapshots(scopeKey: "source:s")
        #expect(store.cachedSnapshot(scopeKey: "source:s", version: version, order: .title) == nil)

        await store.setCatalogServesLists(false)
        _ = await store.snapshot(scopeKey: "library", version: version, order: .title, songs: large)
        #expect(store.cachedSnapshot(scopeKey: "library", version: version, order: .title) != nil)
    }
}
