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

    @Test("iOS 27 prefers Music Understanding only for readable assets")
    func selectsVersionedAnalysisBackend() {
        #expect(SmartMixAnalysisBackendPolicy.preferredBackend(
            operatingSystemMajorVersion: 26,
            musicUnderstandingAvailable: false,
            assetAccess: .completeFile
        ) == .streamingPCM)
        #expect(SmartMixAnalysisBackendPolicy.preferredBackend(
            operatingSystemMajorVersion: 27,
            musicUnderstandingAvailable: true,
            assetAccess: .completeFile
        ) == .musicUnderstanding)
        #expect(SmartMixAnalysisBackendPolicy.preferredBackend(
            operatingSystemMajorVersion: 27,
            musicUnderstandingAvailable: true,
            assetAccess: .protectedSystemStream
        ) == nil)
    }

    @Test("Streaming PCM fallback detects a stable 120 BPM pulse")
    func detectsTempoFromEnergyEnvelope() throws {
        let envelopeRate = 50.0
        let beatFrames = 25
        let phase = 5
        var envelope = Array(repeating: Float(0.02), count: Int(envelopeRate * 24))
        for index in stride(from: phase, to: envelope.count, by: beatFrames) {
            envelope[index] = 1
            if index + 1 < envelope.count { envelope[index + 1] = 0.5 }
        }

        let estimate = try #require(SmartMixRhythmDetector.estimateTempo(
            rmsEnvelope: envelope,
            envelopeSampleRate: envelopeRate
        ))

        #expect(abs(estimate.beatsPerMinute - 120) < 0.1)
        #expect(estimate.confidence >= 0.5)
        #expect(abs(estimate.firstBeatTime - 0.1) < 0.021)
    }

    @Test("Steady energy without rhythmic onsets has no tempo")
    func rejectsSteadyEnergy() {
        let envelope = Array(repeating: Float(0.25), count: 1_000)
        #expect(SmartMixRhythmDetector.estimateTempo(
            rmsEnvelope: envelope,
            envelopeSampleRate: 50
        ) == nil)
    }

    @Test("Tempo analysis rounds overlap to complete four-beat bars")
    func plansTempoAlignedOverlap() throws {
        let analysis = SmartMixTrackAnalysis(
            backend: .streamingPCM,
            analyzedDuration: 32,
            tempo: SmartMixTempoEstimate(
                beatsPerMinute: 128,
                confidence: 0.9,
                firstBeatTime: 0
            )
        )

        let plan = try #require(SmartMixTransitionPlanner.plan(
            nominalDuration: 240,
            analyzedPlayableDuration: 236,
            requestedOverlap: 8,
            analysis: analysis
        ))

        #expect(plan.basis == .tempoGrid)
        #expect(abs(plan.overlapDuration - 7.5) < 0.001)
        #expect(abs(plan.triggerTime - 228.5) < 0.001)
        #expect(plan.playableEndpoint == 236)
    }

    @Test("Framework bar timestamps account for trimmed leading silence")
    func plansFromDetectedBars() throws {
        let analysis = SmartMixTrackAnalysis(
            backend: .musicUnderstanding,
            analyzedDuration: 242,
            tempo: SmartMixTempoEstimate(
                beatsPerMinute: 120,
                confidence: 1,
                firstBeatTime: 2
            ),
            barStartTimes: [2, 10, 18, 230, 238]
        )

        let plan = try #require(SmartMixTransitionPlanner.plan(
            nominalDuration: 240,
            analyzedPlayableDuration: 236,
            requestedOverlap: 8,
            analysis: analysis,
            analysisTimelineOffset: 2
        ))

        #expect(plan.basis == .detectedBar)
        #expect(plan.triggerTime == 228)
        #expect(plan.overlapDuration == 8)
    }

    @Test("Framework section boundaries take priority over ordinary bars")
    func plansFromDetectedSections() throws {
        let analysis = SmartMixTrackAnalysis(
            backend: .musicUnderstanding,
            analyzedDuration: 242,
            tempo: SmartMixTempoEstimate(
                beatsPerMinute: 120,
                confidence: 1,
                firstBeatTime: 2
            ),
            barStartTimes: [228, 230],
            sectionStartTimes: [229]
        )

        let plan = try #require(SmartMixTransitionPlanner.plan(
            nominalDuration: 240,
            analyzedPlayableDuration: 236,
            requestedOverlap: 8,
            analysis: analysis
        ))

        #expect(plan.basis == .detectedSection)
        #expect(plan.triggerTime == 229)
        #expect(plan.overlapDuration == 7)
    }

    @Test("Missing rhythm retains silence-aware fixed overlap")
    func plannerFallsBackWithoutRhythm() throws {
        let plan = try #require(SmartMixTransitionPlanner.plan(
            nominalDuration: 240,
            analyzedPlayableDuration: 234,
            requestedOverlap: 6,
            analysis: nil
        ))

        #expect(plan.basis == .audibleBoundary)
        #expect(plan.triggerTime == 228)
        #expect(plan.overlapDuration == 6)
    }
}
