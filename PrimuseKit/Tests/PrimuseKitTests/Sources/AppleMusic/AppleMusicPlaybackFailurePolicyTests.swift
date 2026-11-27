import Foundation
import Testing
@testable import PrimuseKit

@Suite("Apple Music playback failure guidance")
struct AppleMusicPlaybackFailurePolicyTests {
    private func playerError(underlying: NSError? = nil) -> NSError {
        NSError(
            domain: AppleMusicQueueRecoveryPolicy.musicPlayerErrorDomain,
            code: 6,
            userInfo: underlying.map { [NSUnderlyingErrorKey: $0] } ?? [:]
        )
    }

    @Test("A successful access check followed by error 6 is not an authentication diagnosis")
    func opaqueFailureAfterSuccessfulPreflight() {
        let failure = AppleMusicPlaybackFailurePolicy.classify(playerError(), catalogPlaybackWasVerified: true)
        #expect(failure == .systemPlayerFailedAfterAccessCheck)
        #expect(!failure.stopsSource)
    }

    @Test("Library access or a prior request cannot imply a playback capability check")
    func opaqueFailureWithoutPlaybackPreflight() {
        let failure = AppleMusicPlaybackFailurePolicy.classify(playerError(), catalogPlaybackWasVerified: false)
        #expect(failure == .systemPlayerFailed)
        #expect(!failure.stopsSource)
    }

    @Test("Explicit playback authentication failures override successful preflight and stop skipping",
          arguments: [
            NSError(domain: "AMSErrorDomain", code: 100),
            NSError(domain: "ICError", code: -7403),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorUserAuthenticationRequired),
          ])
    func underlyingAuthenticationFailure(error: NSError) {
        let failure = AppleMusicPlaybackFailurePolicy.classify(
            playerError(underlying: error), catalogPlaybackWasVerified: true
        )
        #expect(failure == .authenticationRequired)
        #expect(failure.stopsSource)
    }

    @Test("MusicKit's explicit signed-out or revoked-token error is an authentication failure")
    func explicitMusicKitAuthenticationFailure() {
        #expect(AppleMusicPlaybackFailurePolicy.classify(
            playerError(), catalogPlaybackWasVerified: false, authenticationRequired: true
        ) == .authenticationRequired)
    }

    @Test("Multiple underlying errors retain authentication evidence")
    func multipleUnderlyingErrors() {
        let error = NSError(domain: "wrapper", code: 1, userInfo: [
            NSMultipleUnderlyingErrorsKey: [
                NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
                playerError(underlying: NSError(domain: "AMSErrorDomain", code: 100)),
            ],
        ])
        #expect(AppleMusicPlaybackFailurePolicy.classify(
            error, catalogPlaybackWasVerified: true
        ) == .authenticationRequired)
    }

    @Test("Matching numbers, diagnostic text and network failures do not imply authentication")
    func unrelatedErrorsRemainDistinct() {
        for error in [
            NSError(domain: "MPCPlaybackEngineInternalError", code: 100),
            NSError(domain: "unknown", code: -7403),
            NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut),
            NSError(domain: "unknown", code: 6, userInfo: [NSLocalizedDescriptionKey: "Authentication Failed"]),
        ] {
            #expect(AppleMusicPlaybackFailurePolicy.classify(
                error, catalogPlaybackWasVerified: true
            ) == .other)
        }
    }
}
