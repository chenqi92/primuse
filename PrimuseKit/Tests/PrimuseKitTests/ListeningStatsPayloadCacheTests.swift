import Foundation
import Testing
@testable import PrimuseKit

@Suite("Listening stats payload cache freshness")
struct ListeningStatsPayloadCacheTests {
    @Test("A payload encoded from the current store revision is reused")
    func usesCacheAtSameRevision() {
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: 7, currentRevision: 7))
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: 0, currentRevision: 0))
    }

    @Test("Any mutation between encode and send invalidates the payload")
    func rejectsCacheAfterMutation() {
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: 7, currentRevision: 8) == false)
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: 0, currentRevision: 1) == false)
    }

    @Test("A cache from a later revision than the store is not usable either")
    func rejectsOutOfOrderRevision() {
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: 9, currentRevision: 8) == false)
    }

    @Test("The wrapped revision counter stays comparable")
    func handlesWrappedRevision() {
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: Int.max, currentRevision: Int.max))
        #expect(ListeningStatsPayloadCache.isUsable(cachedRevision: Int.max, currentRevision: Int.min) == false)
    }
}
