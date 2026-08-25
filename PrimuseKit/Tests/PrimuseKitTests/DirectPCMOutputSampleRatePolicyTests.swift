import Testing
@testable import PrimuseKit

@Suite("Direct PCM output sample rate")
struct DirectPCMOutputSampleRatePolicyTests {
    @Test("A rejected preferred rate uses the actual hardware rate")
    func rejectedRateFallsBack() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 44_100,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
    }

    @Test("A matched preferred rate remains bit-exactly labelled")
    func matchedRateIsPreserved() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 96_000,
            actualHardwareSampleRate: 96_000
        ) == 96_000)
        #expect(DirectPCMOutputSampleRatePolicy.hardwareMatches(
            requestedSampleRate: 96_000,
            actualHardwareSampleRate: 96_000
        ))
    }

    @Test("An unknown or invalid source rate still uses a valid route rate")
    func invalidSourceUsesRoute() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: nil,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: -1,
            actualHardwareSampleRate: 48_000
        ) == 48_000)
    }

    @Test("An unknown hardware rate never trusts the requested label")
    func unknownHardwareDoesNotGuess() {
        #expect(DirectPCMOutputSampleRatePolicy.resolvedSampleRate(
            requestedSourceSampleRate: 192_000,
            actualHardwareSampleRate: 0
        ) == nil)
    }

    @Test("The first decoded buffer must match the configured graph")
    func firstBufferCompatibility() {
        #expect(DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 48_000,
            bufferChannelCount: 2,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 96_000,
            bufferChannelCount: 2,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
        #expect(!DirectPCMOutputSampleRatePolicy.bufferMatchesGraph(
            bufferSampleRate: 48_000,
            bufferChannelCount: 1,
            graphSampleRate: 48_000,
            graphChannelCount: 2
        ))
    }
}
