import Testing
@testable import PrimuseKit

@Suite("Metadata backfill execution")
struct MetadataBackfillExecutionPolicyTests {
    @Test("Background playback remains serial and throttled")
    func playbackFriendlyLimits() {
        let standard = MetadataBackfillExecutionPolicy.limits(for: .standard)
        let background = MetadataBackfillExecutionPolicy.limits(for: .background)
        let playback = MetadataBackfillExecutionPolicy.limits(for: .backgroundDuringPlayback)

        #expect(standard.workerCount == 3)
        #expect(background.workerCount == 1)
        #expect(playback.workerCount == 1)
        #expect(playback.snapshotLimit < background.snapshotLimit)
        #expect(playback.interRequestDelay > background.interRequestDelay)
        #expect(playback.flushInterval >= background.flushInterval)
    }
}
