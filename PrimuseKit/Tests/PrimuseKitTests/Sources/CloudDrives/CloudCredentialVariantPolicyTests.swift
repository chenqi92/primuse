import Foundation
import Testing
@testable import PrimuseKit

@Suite("Cloud credential Keychain variant safety")
struct CloudCredentialVariantPolicyTests {
    @Test("A failed obsolete-variant delete requires an exact mirror")
    func failedCleanupRequiresMirror() {
        #expect(CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: true,
            obsoleteVariantRemoved: true,
            obsoleteVariantMatchesTarget: false,
            obsoleteVariantCannotOverrideTarget: false
        ))
        #expect(CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: true,
            obsoleteVariantRemoved: false,
            obsoleteVariantMatchesTarget: true,
            obsoleteVariantCannotOverrideTarget: false
        ))
        #expect(!CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: true,
            obsoleteVariantRemoved: false,
            obsoleteVariantMatchesTarget: false,
            obsoleteVariantCannotOverrideTarget: false
        ))
        #expect(!CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: false,
            obsoleteVariantRemoved: true,
            obsoleteVariantMatchesTarget: true,
            obsoleteVariantCannotOverrideTarget: true
        ))
    }

    @Test("An inaccessible sync variant preserves the local-only fallback")
    func inaccessibleSyncVariantCannotOverrideLocalFallback() {
        #expect(CloudCredentialVariantPolicy.isWriteSafe(
            targetStored: true,
            obsoleteVariantRemoved: false,
            obsoleteVariantMatchesTarget: false,
            obsoleteVariantCannotOverrideTarget: true
        ))
    }

    @Test("Launch migration never overwrites a newer synchronizable rotation")
    func staleLocalCannotRollBackSynchronizableToken() {
        let oldLocal = Date(timeIntervalSince1970: 100)
        let rotatedSynchronizable = Date(timeIntervalSince1970: 200)

        #expect(!CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: oldLocal,
            synchronizableModifiedAt: rotatedSynchronizable
        ))
    }

    @Test("A genuinely newer local value still migrates when sync is enabled")
    func newerLocalMigrates() {
        let oldSynchronizable = Date(timeIntervalSince1970: 100)
        let newLocal = Date(timeIntervalSince1970: 200)

        #expect(CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: newLocal,
            synchronizableModifiedAt: oldSynchronizable
        ))
    }

    @Test("Ties or unavailable modification metadata preserve sync authority")
    func ambiguousMigrationPreservesSynchronizableValue() {
        let same = Date(timeIntervalSince1970: 100)

        #expect(!CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: same,
            synchronizableModifiedAt: same
        ))
        #expect(!CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: nil,
            synchronizableModifiedAt: same
        ))
        #expect(!CloudCredentialVariantPolicy.shouldReplaceSynchronizableValue(
            localModifiedAt: same,
            synchronizableModifiedAt: nil
        ))
    }
}
