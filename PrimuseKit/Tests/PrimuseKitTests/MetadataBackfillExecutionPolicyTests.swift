import Testing
@testable import PrimuseKit

@Suite("Metadata backfill execution")
struct MetadataBackfillExecutionPolicyTests {
    @Test("Bare-only sources stop after their initial detail read")
    func bareOnlyEligibility() {
        let pending = MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .flac,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true
        )
        let completed = MetadataBackfillEligibilityPolicy.reasons(
            duration: 180,
            format: .flac,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true
        )
        let terminalIncomplete = MetadataBackfillEligibilityPolicy.reasons(
            duration: 0,
            format: .dts,
            hasCoverArt: false,
            artworkGivenUp: false,
            titleChecked: false,
            restrictToBareRows: true,
            durationInspectionComplete: true
        )

        #expect(pending.contains(.duration))
        #expect(pending.contains(.title))
        #expect(completed.isEmpty)
        #expect(terminalIncomplete.isEmpty)
    }

    @Test("Background work is serial, throttled, and bounded per wake")
    func boundedBackgroundLimits() {
        let standard = MetadataBackfillExecutionPolicy.limits(for: .standard)
        let userInitiated = MetadataBackfillExecutionPolicy.limits(for: .userInitiated)
        let foreground = MetadataBackfillExecutionPolicy.limits(
            for: .foregroundAfterSourceScan
        )
        let background = MetadataBackfillExecutionPolicy.limits(for: .background)
        let playback = MetadataBackfillExecutionPolicy.limits(for: .backgroundDuringPlayback)

        #expect(standard.workerCount == 3)
        #expect(standard.snapshotPassLimit == nil)
        #expect(userInitiated.workerCount == 1)
        #expect(userInitiated.snapshotLimit > foreground.snapshotLimit)
        #expect(userInitiated.interRequestDelay > 0)
        #expect(userInitiated.snapshotPassLimit == nil)
        #expect(foreground.workerCount == 1)
        #expect(foreground.snapshotLimit <= background.snapshotLimit)
        #expect(foreground.interRequestDelay >= background.interRequestDelay)
        #expect(foreground.snapshotPassLimit == 1)
        #expect(background.workerCount == 1)
        #expect(background.snapshotPassLimit == 1)
        #expect(playback.workerCount == 1)
        #expect(playback.snapshotLimit < background.snapshotLimit)
        #expect(playback.interRequestDelay > background.interRequestDelay)
        #expect(playback.flushInterval >= background.flushInterval)
        #expect(playback.snapshotPassLimit == 1)
    }
}
