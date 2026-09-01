import Testing
@testable import PrimuseKit

@Suite("Playback URL request ownership")
struct PlaybackURLRequestPolicyTests {
    @Test("The active request may begin with a current stream epoch")
    func acceptsActiveRequest() {
        #expect(PlaybackURLRequestPolicy.canBegin(
            requestID: 9,
            activeRequestID: 9,
            isCancelled: false,
            requiresCurrentStreamEpoch: true,
            streamEpochIsCurrent: true
        ))
    }

    @Test("A delayed format retry cannot reclaim playback after a track switch")
    func rejectsSupersededFormatRetry() {
        #expect(!PlaybackURLRequestPolicy.canBegin(
            requestID: 8,
            activeRequestID: 9,
            isCancelled: false,
            requiresCurrentStreamEpoch: true,
            streamEpochIsCurrent: true
        ))
    }

    @Test("Cancellation and stale stream epochs stop remote playback setup")
    func rejectsInvalidRemoteSetup() {
        #expect(!PlaybackURLRequestPolicy.canBegin(
            requestID: 9,
            activeRequestID: 9,
            isCancelled: true,
            requiresCurrentStreamEpoch: true,
            streamEpochIsCurrent: true
        ))
        #expect(!PlaybackURLRequestPolicy.canBegin(
            requestID: 9,
            activeRequestID: 9,
            isCancelled: false,
            requiresCurrentStreamEpoch: true,
            streamEpochIsCurrent: false
        ))
    }

    @Test("Local playback does not depend on a remote stream epoch")
    func acceptsActiveLocalRequest() {
        #expect(PlaybackURLRequestPolicy.canBegin(
            requestID: 9,
            activeRequestID: 9,
            isCancelled: false,
            requiresCurrentStreamEpoch: false,
            streamEpochIsCurrent: false
        ))
    }
}
