import Testing
@testable import PrimuseKit

@Suite("Paused pipeline resume")
struct PausedPipelineResumePolicyTests {
    private func evidence(
        pipelineIsUnchanged: Bool = true,
        recoveryWasArmedBeforePause: Bool = false,
        pausedFor: Double = 5,
        hasPreparedAudio: Bool = true,
        isAtTrackEnd: Bool = false,
        isLoading: Bool = false,
        isTransitioning: Bool = false,
        outputGraphNeedsRebuild: Bool = false,
        finalBufferAlreadyScheduled: Bool = false,
        decoderIsAlive: Bool = true
    ) -> PausedPipelineResumePolicy.Evidence {
        .init(
            pipelineIsUnchanged: pipelineIsUnchanged,
            recoveryWasArmedBeforePause: recoveryWasArmedBeforePause,
            pausedFor: pausedFor,
            hasPreparedAudio: hasPreparedAudio,
            isAtTrackEnd: isAtTrackEnd,
            isLoading: isLoading,
            isTransitioning: isTransitioning,
            outputGraphNeedsRebuild: outputGraphNeedsRebuild,
            finalBufferAlreadyScheduled: finalBufferAlreadyScheduled,
            decoderIsAlive: decoderIsAlive
        )
    }

    @Test("A short pause of an intact pipeline plays on in place")
    func shortPauseResumesInPlace() {
        #expect(PausedPipelineResumePolicy.canResumeInPlace(evidence()))
        #expect(PausedPipelineResumePolicy.canResumeInPlace(evidence(
            pausedFor: PausedPipelineResumePolicy.maximumPauseDuration
        )))
    }

    @Test("Any disturbance since the pause rebuilds instead")
    func disturbanceRebuilds() {
        let disturbed: [PausedPipelineResumePolicy.Evidence] = [
            evidence(pipelineIsUnchanged: false),
            evidence(recoveryWasArmedBeforePause: true),
            evidence(pausedFor: PausedPipelineResumePolicy.maximumPauseDuration + 1),
            evidence(pausedFor: -1),
            evidence(hasPreparedAudio: false),
            evidence(isAtTrackEnd: true),
            evidence(isLoading: true),
            evidence(isTransitioning: true),
            evidence(outputGraphNeedsRebuild: true),
            evidence(finalBufferAlreadyScheduled: true),
            evidence(decoderIsAlive: false),
        ]
        for item in disturbed {
            #expect(!PausedPipelineResumePolicy.canResumeInPlace(item))
        }
    }

    @Test("A first buffer stalls only after the source has gone quiet")
    func firstBufferStall() {
        #expect(!SeekFirstBufferStallPolicy.hasStalled(
            startedAt: 100, lastTransferAt: nil, now: 134, timeout: 35
        ))
        #expect(SeekFirstBufferStallPolicy.hasStalled(
            startedAt: 100, lastTransferAt: nil, now: 135, timeout: 35
        ))
        // Bytes still arriving keep a slow source alive.
        #expect(!SeekFirstBufferStallPolicy.hasStalled(
            startedAt: 100, lastTransferAt: 130, now: 160, timeout: 35
        ))
        // Delivery from before the start does not extend it.
        #expect(SeekFirstBufferStallPolicy.hasStalled(
            startedAt: 100, lastTransferAt: 40, now: 136, timeout: 35
        ))
    }

    @Test("Transfers wait for conditions to settle after they recover")
    func transferSettle() {
        var gate = TransferConditionSettleGate(allowed: true, settleInterval: 20)
        #expect(gate.allowsStart(now: 0))

        gate.observe(allowed: false, now: 10)
        #expect(!gate.allowsStart(now: 10))
        #expect(gate.remainingSettle(now: 10) == nil)

        gate.observe(allowed: true, now: 12)
        #expect(!gate.allowsStart(now: 20))
        #expect(gate.remainingSettle(now: 20) == 12)

        // Flipping back before the window ends starts it over.
        gate.observe(allowed: false, now: 25)
        gate.observe(allowed: true, now: 26)
        #expect(!gate.allowsStart(now: 40))
        #expect(gate.allowsStart(now: 46))
        #expect(gate.remainingSettle(now: 46) == nil)

        // A repeated good report does not restart the window.
        gate.observe(allowed: true, now: 50)
        #expect(gate.allowsStart(now: 50))
    }

    @Test("Conditions blocked at launch settle once they turn good")
    func blockedAtLaunch() {
        var gate = TransferConditionSettleGate(allowed: false, settleInterval: 20)
        #expect(!gate.allowsStart(now: 0))
        gate.observe(allowed: true, now: 5)
        #expect(!gate.allowsStart(now: 24))
        #expect(gate.allowsStart(now: 25))
    }
}
