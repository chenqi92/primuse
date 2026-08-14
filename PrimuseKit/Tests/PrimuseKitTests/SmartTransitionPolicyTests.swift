import Testing
@testable import PrimuseKit

@Suite("Smart transition policy")
struct SmartTransitionPolicyTests {
    @Test("Signal boundaries ignore quiet windows at both ends")
    func detectsAudibleWindows() {
        let samples: [Float] = Array(repeating: 0, count: 20)
            + Array(repeating: 0.25, count: 50)
            + Array(repeating: 0, count: 30)

        let range = AudioSignalBoundaryDetector.audibleFrameRange(
            frameCount: samples.count,
            channelCount: 1,
            sampleRate: 1_000,
            windowDuration: 0.01,
            sampleAt: { frame, _ in samples[frame] }
        )

        #expect(range == 20..<70)
    }

    @Test("Sub-threshold noise remains silence")
    func rejectsLowLevelNoise() {
        let samples = Array(repeating: Float(0.001), count: 100)
        let range = AudioSignalBoundaryDetector.audibleFrameRange(
            frameCount: samples.count,
            channelCount: 1,
            sampleRate: 1_000,
            sampleAt: { frame, _ in samples[frame] }
        )

        #expect(range == nil)
    }

    @Test("Analyzed tail silence advances the transition")
    func usesAnalyzedEndpoint() {
        #expect(SmartTransitionPolicy.triggerTime(
            nominalDuration: 240,
            analyzedPlayableDuration: 234,
            requestedOverlap: 4
        ) == 230)
    }

    @Test("Missing or invalid analysis falls back to fixed crossfade")
    func fallsBackToNominalDuration() {
        #expect(SmartTransitionPolicy.triggerTime(
            nominalDuration: 240,
            analyzedPlayableDuration: 260,
            requestedOverlap: 4
        ) == 236)
        #expect(SmartTransitionPolicy.triggerTime(
            nominalDuration: 240,
            analyzedPlayableDuration: nil,
            requestedOverlap: 4
        ) == 236)
    }

    @Test("Late analysis shortens the overlap without a hard cut")
    func shortensLateOverlap() {
        #expect(SmartTransitionPolicy.effectiveOverlap(
            requestedOverlap: 8,
            currentTime: 232,
            playableEndpoint: 235
        ) == 3)
        #expect(SmartTransitionPolicy.effectiveOverlap(
            requestedOverlap: 8,
            currentTime: 235,
            playableEndpoint: 235
        ) == 0.5)
    }
}
