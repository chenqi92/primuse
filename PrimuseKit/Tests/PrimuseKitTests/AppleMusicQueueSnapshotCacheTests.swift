import Testing
@testable import PrimuseKit

@Suite("Apple Music queue snapshot work")
struct AppleMusicQueueSnapshotCacheTests {
    @Test("A Primuse-owned queue never reads or resolves native entries")
    func skipsManagedQueueWork() {
        var cache = AppleMusicQueueSnapshotCache()
        var entryReads = 0
        var resolvedSongs = 0
        for _ in 0..<20 {
            let snapshot: [Int]? = cache.snapshotIfChanged(
                primuseOwnsCanonicalQueue: true,
                entryIDs: { entryReads += 1; return (0..<101).map(String.init) },
                project: { resolvedSongs += 101; return Array(0..<101) }
            )
            #expect(snapshot == nil)
        }
        #expect(entryReads == 0)
        #expect(resolvedSongs == 0)
    }

    @Test("Unchanged native entries reuse the projection, including while paused")
    func skipsUnchangedNativeQueue() {
        var cache = AppleMusicQueueSnapshotCache()
        var projections = 0
        for tick in 0..<20 {
            let snapshot = cache.snapshotIfChanged(
                primuseOwnsCanonicalQueue: false,
                entryIDs: { ["a-1", "b", "a-2"] },
                project: { projections += 1; return ["A", "B", "A"] }
            )
            #expect(snapshot == (tick == 0 ? ["A", "B", "A"] : nil))
        }
        #expect(projections == 1)
    }

    @Test("Reordering repeated occurrences and replacing resolved IDs refresh the snapshot")
    func refreshesChangedNativeQueue() {
        var cache = AppleMusicQueueSnapshotCache()
        for ids in [["a-1", "b", "a-2"], ["a-2", "a-1", "b"], ["resolved-a", "resolved-b"]] {
            let snapshot = cache.snapshotIfChanged(
                primuseOwnsCanonicalQueue: false, entryIDs: { ids }, project: { ids }
            )
            #expect(snapshot == ids)
        }
    }

    @Test("Returning from Primuse ownership rebuilds even if native IDs are reused")
    func invalidatesAcrossOwnershipChanges() {
        var cache = AppleMusicQueueSnapshotCache()
        var projections = 0
        for managed in [false, true, false] {
            let snapshot = cache.snapshotIfChanged(
                primuseOwnsCanonicalQueue: managed,
                entryIDs: { ["same-entry"] },
                project: { projections += 1; return [projections] }
            )
            #expect(managed ? snapshot == nil : snapshot != nil)
        }
        #expect(projections == 2)
    }
}
