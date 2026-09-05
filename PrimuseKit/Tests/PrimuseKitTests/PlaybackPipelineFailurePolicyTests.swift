import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback pipeline failure recovery")
struct PlaybackPipelineFailurePolicyTests {
    @Test("Audio ownership failures preserve a healthy song instead of skipping it",
          arguments: [560557684, 561017449, 2003329396])
    func audioSessionFailurePreservesSelection(code: Int) {
        let error = PlaybackAudioSessionFailure(NSError(
            domain: NSOSStatusErrorDomain,
            code: code
        ))
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: true,
            error: error
        ) == .preserveCurrentItem)
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: false,
            error: error
        ) == .discardStaleResult)
        #expect(error.underlyingError.code == code)
    }

    @Test("Decoder errors remain eligible for queue recovery")
    func decoderFailureIsNotAnAudioSessionFailure() {
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: true,
            error: NSError(domain: "decoder", code: 2003329396)
        ) == .advanceAfterFailure)
    }

    @Test("A transient cancellation preserves the selected item and queue")
    func cancellationPreservesSelection() {
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: true,
            errorIsCancellation: true
        ) == .preserveCurrentItem)
    }

    @Test("An obsolete request cannot mutate the replacement transport")
    func staleRequestIsDiscarded() {
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: false,
            errorIsCancellation: false
        ) == .discardStaleResult)
    }

    @Test("Only a current real failure enters queue recovery")
    func realFailureMayAdvance() {
        #expect(PlaybackPipelineFailurePolicy.action(
            requestIsCurrent: true,
            errorIsCancellation: false
        ) == .advanceAfterFailure)
    }

    @Test("Display-only source updates leave active playback untouched")
    func metadataOnlySourceChangeIsIgnored() {
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "same-scope",
            currentScopeFingerprint: "same-scope"
        ) == .ignoreNonSecurityChange)
    }

    @Test("Endpoint changes and source removal invalidate the security scope")
    func securityScopeChangesAreInvalidated() {
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: "new-scope"
        ) == .invalidateSecurityScope)
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: nil
        ) == .invalidateSecurityScope)
    }
}
