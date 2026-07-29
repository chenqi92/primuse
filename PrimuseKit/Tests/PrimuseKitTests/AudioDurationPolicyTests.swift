import Testing
@testable import PrimuseKit

@Suite("Audio duration policy")
struct AudioDurationPolicyTests {
    @Test("DTS fallback uses full-rate DTS instead of generic lossy bitrate")
    func dtsFallbackEstimate() {
        let duration = AudioDurationPolicy.fallbackEstimate(
            fileSize: 60_819_456,
            format: .dts
        )
        #expect(abs(duration - 316.768) < 0.001)
    }

    @Test("Complete-file decoder corrects an inflated scan duration")
    func completeFileDurationIsAuthoritative() {
        #expect(!AudioDurationPolicy.shouldIgnoreResolvedDuration(
            resolved: 316.813,
            stored: 2_534.144,
            fileSize: 60_819_456,
            bitRateKbps: nil,
            format: .dts,
            formatRequiresCompleteLocalFile: true
        ))
    }

    @Test("Partial range duration remains rejected for streamable files")
    func partialRangeDurationIsRejected() {
        #expect(AudioDurationPolicy.shouldIgnoreResolvedDuration(
            resolved: 30,
            stored: 300,
            fileSize: 12_000_000,
            bitRateKbps: 320,
            format: .mp3,
            formatRequiresCompleteLocalFile: false
        ))
    }
}
