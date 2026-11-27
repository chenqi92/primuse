import Foundation
import Testing
@testable import PrimuseKit

@Suite("Crossfade pump continuation policy")
struct CrossfadePumpContinuationPolicyTests {
    @Test("The owning pump keeps feeding the primary node")
    func currentOwnerMayContinue() {
        let playID = UUID()

        #expect(
            CrossfadePumpContinuationPolicy.mayContinue(
                playID: playID,
                currentPlayID: playID,
                isCrossfading: false,
                outgoingPlayID: nil
            )
        )
    }

    @Test("Ordinary supersession retires the superseded pump")
    func supersededPumpStops() {
        let outgoing = UUID()

        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: outgoing,
                currentPlayID: UUID(),
                isCrossfading: false,
                outgoingPlayID: nil
            )
        )
    }

    @Test("A committed crossfade keeps the outgoing pump alive through the ramp")
    func committedCrossfadeGrantsGrace() {
        let outgoing = UUID()
        let incoming = UUID()

        #expect(
            CrossfadePumpContinuationPolicy.mayContinue(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: outgoing
            )
        )
        // The incoming owner is unaffected by the grace.
        #expect(
            CrossfadePumpContinuationPolicy.mayContinue(
                playID: incoming,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: outgoing
            )
        )
    }

    @Test("Completing, failing or cancelling the transition ends the grace")
    func clearedTransitionEndsGrace() {
        let outgoing = UUID()
        let incoming = UUID()

        // completeCrossfade clears both the flag and the committed transition.
        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: false,
                outgoingPlayID: nil
            )
        )
        // A cleared committed transition alone is enough to end it.
        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: nil
            )
        )
        // So is a cleared flag while a stale committed record is still around.
        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: false,
                outgoingPlayID: outgoing
            )
        )
    }

    @Test("A third play ID never inherits another transition's grace")
    func unrelatedPumpStaysRetired() {
        let outgoing = UUID()
        let incoming = UUID()
        let stale = UUID()

        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: stale,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: outgoing
            )
        )
    }

    @Test("Playback without an owner retires every pump")
    func missingOwnerRetiresPumps() {
        let playID = UUID()

        #expect(
            !CrossfadePumpContinuationPolicy.mayContinue(
                playID: playID,
                currentPlayID: UUID?.none,
                isCrossfading: true,
                outgoingPlayID: nil
            )
        )
    }
}

@Suite("Primary pump final buffer policy")
struct PrimaryPumpFinalBufferPolicyTests {
    @Test("The owning pump keeps the track-end completion")
    func currentOwnerKeepsTrackEndCallback() {
        let playID = UUID()

        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: playID,
                currentPlayID: playID,
                isCrossfading: false,
                outgoingPlayID: nil
            ) == .scheduleWithTrackEnd
        )
        // A crossfade in flight does not change the incoming owner's ending.
        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: playID,
                currentPlayID: playID,
                isCrossfading: true,
                outgoingPlayID: UUID()
            ) == .scheduleWithTrackEnd
        )
    }

    @Test("The outgoing pump still hears its held-back tail during the ramp")
    func outgoingPumpSchedulesTailWithoutCallbacks() {
        let outgoing = UUID()
        let incoming = UUID()

        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: outgoing
            ) == .scheduleOutgoingTail
        )
    }

    @Test("A retired pump drops its tail instead of advancing the queue")
    func retiredPumpDropsTail() {
        let outgoing = UUID()
        let incoming = UUID()
        let stale = UUID()

        // Ordinary supersession — no grace at all.
        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: false,
                outgoingPlayID: nil
            ) == .drop
        )
        // The transition finished or was cancelled mid-decode.
        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: outgoing,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: nil
            ) == .drop
        )
        // A third play ID never inherits another transition's grace.
        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: stale,
                currentPlayID: incoming,
                isCrossfading: true,
                outgoingPlayID: outgoing
            ) == .drop
        )
        // Playback without an owner and without a live transition.
        #expect(
            PrimaryPumpFinalBufferPolicy.disposition(
                playID: outgoing,
                currentPlayID: UUID?.none,
                isCrossfading: true,
                outgoingPlayID: nil
            ) == .drop
        )
    }
}
