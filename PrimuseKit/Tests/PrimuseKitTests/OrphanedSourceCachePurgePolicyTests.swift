import Testing
@testable import PrimuseKit

@Suite("Orphaned source cache purge policy")
struct OrphanedSourceCachePurgePolicyTests {
    @Test("A plain orphan is purged")
    func plainOrphanIsPurged() {
        #expect(OrphanedSourceCachePurgePolicy.sourceIDsToPurge(
            observedOrphans: ["gone-1", "gone-2"],
            liveSourceIDs: ["alive"],
            sourceIDsWithInFlightTransfers: []
        ) == ["gone-1", "gone-2"])
    }

    @Test("A source re-added during the directory walk is kept")
    func reappearedSourceIsKept() {
        #expect(OrphanedSourceCachePurgePolicy.sourceIDsToPurge(
            observedOrphans: ["reappeared", "gone"],
            liveSourceIDs: ["reappeared"],
            sourceIDsWithInFlightTransfers: []
        ) == ["gone"])
    }

    @Test("An orphan with an in-flight transfer is only purged after cancellation")
    func inFlightTransferDefersPurge() {
        #expect(OrphanedSourceCachePurgePolicy.sourceIDsToPurge(
            observedOrphans: ["downloading"],
            liveSourceIDs: [],
            sourceIDsWithInFlightTransfers: ["downloading"]
        ).isEmpty)
        // The caller cancels the orphan's transfers first; the same orphan is
        // then purgeable in the very same pass.
        #expect(OrphanedSourceCachePurgePolicy.sourceIDsToPurge(
            observedOrphans: ["downloading"],
            liveSourceIDs: [],
            sourceIDsWithInFlightTransfers: []
        ) == ["downloading"])
    }

    @Test("Empty inputs purge nothing")
    func emptyInputsPurgeNothing() {
        #expect(OrphanedSourceCachePurgePolicy.sourceIDsToPurge(
            observedOrphans: [],
            liveSourceIDs: ["alive"],
            sourceIDsWithInFlightTransfers: ["alive"]
        ).isEmpty)
    }
}
