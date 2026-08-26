import Testing
@testable import PrimuseKit

@Suite("Metadata backfill execution")
struct MetadataBackfillExecutionPolicyTests {
    @Test("Background playback remains serial and throttled")
    func playbackFriendlyLimits() {
        let standard = MetadataBackfillExecutionPolicy.limits(for: .standard)
        let foreground = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan
        )
        let background = MetadataBackfillExecutionPolicy.limits(for: .background)
        let playback = MetadataBackfillExecutionPolicy.limits(for: .backgroundDuringPlayback)

        #expect(standard.workerCount == 3)
        #expect(standard.snapshotPassLimit == nil)
        #expect(foreground.workerCount == 1)
        #expect(foreground.snapshotLimit <= background.snapshotLimit)
        #expect(foreground.interRequestDelay >= background.interRequestDelay)
        #expect(foreground.snapshotPassLimit == 1)
        #expect(background.workerCount == 1)
        #expect(background.snapshotPassLimit == nil)
        #expect(playback.workerCount == 1)
        #expect(playback.snapshotLimit < background.snapshotLimit)
        #expect(playback.interRequestDelay > background.interRequestDelay)
        #expect(playback.flushInterval >= background.flushInterval)
    }
}
