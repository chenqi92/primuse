import Testing
@testable import PrimuseKit

@Suite("Source Cache Presentation Policy")
struct SourceCachePresentationPolicyTests {
    @Test("No explicit batch leaves a source idle")
    func incidentalSongDownloadCannotPresentWholeSourceProgress() {
        let state = SourceCachePresentationPolicy.resolve(
            sourceID: "synology",
            preparingSourceID: nil,
            locallyTrackedBatchSourceID: nil,
            activeBatchSourceIDs: []
        )

        #expect(!state.isCurrentSourceBusy)
        #expect(!state.isCachingCurrentSource)
        #expect(!state.isBlockedByAnotherSource)
    }

    @Test("A locally tracked or service-owned explicit batch stays visible")
    func explicitBatchPresentsWholeSourceProgress() {
        let local = SourceCachePresentationPolicy.resolve(
            sourceID: "synology",
            preparingSourceID: nil,
            locallyTrackedBatchSourceID: "synology",
            activeBatchSourceIDs: []
        )
        let restored = SourceCachePresentationPolicy.resolve(
            sourceID: "synology",
            preparingSourceID: nil,
            locallyTrackedBatchSourceID: nil,
            activeBatchSourceIDs: ["synology"]
        )

        #expect(local.isCachingCurrentSource)
        #expect(restored.isCachingCurrentSource)
    }

    @Test("Another explicit source batch blocks starting a second batch")
    func anotherSourceBatchBlocksOnlyBatchAction() {
        let state = SourceCachePresentationPolicy.resolve(
            sourceID: "synology",
            preparingSourceID: nil,
            locallyTrackedBatchSourceID: nil,
            activeBatchSourceIDs: ["baidu"]
        )

        #expect(!state.isCurrentSourceBusy)
        #expect(state.isBlockedByAnotherSource)
    }

    @Test("Preparation remains distinct from active caching")
    func preparationHasItsOwnBusyState() {
        let state = SourceCachePresentationPolicy.resolve(
            sourceID: "synology",
            preparingSourceID: "synology",
            locallyTrackedBatchSourceID: nil,
            activeBatchSourceIDs: []
        )

        #expect(state.isPreparingCurrentSource)
        #expect(state.isCurrentSourceBusy)
        #expect(!state.isCachingCurrentSource)
    }
}
