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

    @Test("A background refusal of exclusive playback retries as mixable")
    func backgroundRefusalRetriesMixable() {
        #expect(PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: 560557684,
            fallbackIsActive: false,
            capturesMicrophone: false,
            alreadyMixable: false
        ))
        // 别的失败(没权限、硬件忙)换成可混音也不会好, 照旧交给上层保留当前歌。
        #expect(!PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: 561017449,
            fallbackIsActive: false,
            capturesMicrophone: false,
            alreadyMixable: false
        ))
        // 卡拉OK录音要 playAndRecord; 用户自己开了混音时根本不会被拒。
        #expect(!PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: 560557684,
            fallbackIsActive: false,
            capturesMicrophone: true,
            alreadyMixable: false
        ))
        #expect(!PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: 560557684,
            fallbackIsActive: false,
            capturesMicrophone: false,
            alreadyMixable: true
        ))
    }

    @Test("A failed return to exclusive playback keeps the mixable session playing")
    func failedExclusiveRestoreKeepsMixableSession() {
        #expect(PlaybackSessionBackgroundActivationPolicy.shouldRetryAsMixable(
            failureCode: 561017449,
            fallbackIsActive: true,
            capturesMicrophone: false,
            alreadyMixable: false
        ))
    }

    @Test("Exclusive playback is restored only while no other app is sounding")
    func exclusiveRestoreWaitsForSilence() {
        #expect(PlaybackSessionBackgroundActivationPolicy.shouldAttemptExclusiveRestore(
            fallbackIsActive: true,
            otherAudioIsPlaying: false
        ))
        #expect(!PlaybackSessionBackgroundActivationPolicy.shouldAttemptExclusiveRestore(
            fallbackIsActive: true,
            otherAudioIsPlaying: true
        ))
        #expect(!PlaybackSessionBackgroundActivationPolicy.shouldAttemptExclusiveRestore(
            fallbackIsActive: false,
            otherAudioIsPlaying: false
        ))
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

    @Test("Adding an alternate address rebuilds routes without a security reset")
    func alternateAddressIsRouteOnly() {
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: "new-scope",
            previousCredentialScopeFingerprint: "same-credentials",
            currentCredentialScopeFingerprint: "same-credentials"
        ) == .rebuildRoutesOnly)
    }

    @Test("An unprovable previous credential scope stays fail-closed")
    func unknownCredentialScopeStaysFailClosed() {
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: "new-scope",
            previousCredentialScopeFingerprint: nil,
            currentCredentialScopeFingerprint: "same-credentials"
        ) == .invalidateSecurityScope)
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: "new-scope",
            previousCredentialScopeFingerprint: "same-credentials",
            currentCredentialScopeFingerprint: nil
        ) == .invalidateSecurityScope)
        #expect(SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: "old-scope",
            currentScopeFingerprint: "new-scope",
            previousCredentialScopeFingerprint: "old-credentials",
            currentCredentialScopeFingerprint: "new-credentials"
        ) == .invalidateSecurityScope)
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
