import Testing
@testable import PrimuseKit

@Suite("Playback request generation policy")
struct PlaybackRequestGenerationPolicyTests {
    @Test("Only the active request may apply a result")
    func acceptsCurrentRequest() {
        #expect(PlaybackRequestGenerationPolicy.shouldApplyResult(
            requestID: 7,
            activeRequestID: 7,
            isCancelled: false
        ))
    }

    @Test("A superseded request cannot overwrite the current selection")
    func rejectsSupersededRequest() {
        #expect(!PlaybackRequestGenerationPolicy.shouldApplyResult(
            requestID: 6,
            activeRequestID: 7,
            isCancelled: false
        ))
    }

    @Test("Cancellation wins even while the generation is still current")
    func rejectsCancelledRequest() {
        #expect(!PlaybackRequestGenerationPolicy.shouldApplyResult(
            requestID: 7,
            activeRequestID: 7,
            isCancelled: true
        ))
    }
}

@Suite("Apple Music playback ownership policy")
struct AppleMusicPlaybackOwnershipPolicyTests {
    @Test("Every local entry waits for an in-flight casting handoff")
    func waitsForCastingHandoff() {
        #expect(AppleMusicPlaybackOwnershipPolicy.shouldAwaitCastingHandoff(
            isLocalPlayback: true,
            hasPendingHandoff: true
        ))
        #expect(!AppleMusicPlaybackOwnershipPolicy.shouldAwaitCastingHandoff(
            isLocalPlayback: false,
            hasPendingHandoff: true
        ))
        #expect(!AppleMusicPlaybackOwnershipPolicy.shouldAwaitCastingHandoff(
            isLocalPlayback: true,
            hasPendingHandoff: false
        ))
    }

    @Test("Casting rejects both visible and pending Apple Music ownership")
    func rejectsAppleMusicOwnership() {
        #expect(!AppleMusicPlaybackOwnershipPolicy.canStartCasting(
            isAppleMusicMode: true,
            hasActivePlaybackRequest: false
        ))
        #expect(!AppleMusicPlaybackOwnershipPolicy.canStartCasting(
            isAppleMusicMode: false,
            hasActivePlaybackRequest: true
        ))
        #expect(AppleMusicPlaybackOwnershipPolicy.canStartCasting(
            isAppleMusicMode: false,
            hasActivePlaybackRequest: false
        ))
    }

    @Test("Apple Music terminal state retains its mirror generation")
    func retainsAppleMusicGenerationAtTrackEnd() {
        #expect(!AppleMusicPlaybackOwnershipPolicy.shouldInvalidatePlayIDAtTrackEnd(
            isAppleMusicMode: true,
            hasActivePlaybackRequest: false
        ))
        #expect(!AppleMusicPlaybackOwnershipPolicy.shouldInvalidatePlayIDAtTrackEnd(
            isAppleMusicMode: false,
            hasActivePlaybackRequest: true
        ))
        #expect(AppleMusicPlaybackOwnershipPolicy.shouldInvalidatePlayIDAtTrackEnd(
            isAppleMusicMode: false,
            hasActivePlaybackRequest: false
        ))
    }
}

@Suite("Apple Music library playback gate policy")
struct AppleMusicLibraryPlaybackGatePolicyTests {
    @Test("All request and environment gates must remain valid")
    func requiresEveryGate() {
        #expect(AppleMusicLibraryPlaybackGatePolicy.canContinue(
            requestIsPending: true,
            isCancelled: false,
            syncEnabled: true,
            sourceEnabled: true,
            isAuthorized: true
        ))

        let rejectedInputs: [(Bool, Bool, Bool, Bool, Bool)] = [
            (false, false, true, true, true),
            (true, true, true, true, true),
            (true, false, false, true, true),
            (true, false, true, false, true),
            (true, false, true, true, false),
        ]
        for input in rejectedInputs {
            #expect(!AppleMusicLibraryPlaybackGatePolicy.canContinue(
                requestIsPending: input.0,
                isCancelled: input.1,
                syncEnabled: input.2,
                sourceEnabled: input.3,
                isAuthorized: input.4
            ))
        }
    }
}

@Suite("Playback error dismissal policy")
struct PlaybackErrorDismissalPolicyTests {
    @Test("Only the same request and message may dismiss an error")
    func rejectsStaleDismissals() {
        #expect(PlaybackErrorDismissalPolicy.shouldDismiss(
            requestID: 4,
            activeRequestID: 4,
            scheduledMessage: "old",
            currentMessage: "old",
            isCancelled: false
        ))
        #expect(!PlaybackErrorDismissalPolicy.shouldDismiss(
            requestID: 3,
            activeRequestID: 4,
            scheduledMessage: "same",
            currentMessage: "same",
            isCancelled: false
        ))
        #expect(!PlaybackErrorDismissalPolicy.shouldDismiss(
            requestID: 4,
            activeRequestID: 4,
            scheduledMessage: "old",
            currentMessage: "new",
            isCancelled: false
        ))
        #expect(!PlaybackErrorDismissalPolicy.shouldDismiss(
            requestID: 4,
            activeRequestID: 4,
            scheduledMessage: "same",
            currentMessage: "same",
            isCancelled: true
        ))
    }
}
