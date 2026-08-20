import Foundation
import Testing
@testable import PrimuseKit

@Suite("Source permanent deletion policy")
struct SourcePermanentDeletionPolicyTests {
    @Test("Recoverable deletion uses one 30-day window")
    func recoverableDeletionWindow() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let deletedAt = now.addingTimeInterval(-29 * 86_400)

        #expect(RecoverableDeletionPolicy.retentionDays == 30)
        #expect(RecoverableDeletionPolicy.pruneThreshold(now: now) == now.addingTimeInterval(-30 * 86_400))
        #expect(RecoverableDeletionPolicy.daysRemaining(deletedAt: deletedAt, now: now) == 1)
        #expect(RecoverableDeletionPolicy.daysRemaining(deletedAt: now.addingTimeInterval(-31 * 86_400), now: now) == 0)
    }

    @Test("Source type selects only credential stores it can own")
    func requiredStoresFollowSourceType() {
        let passwordOnly = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: .smb,
            authType: .password
        )
        #expect(passwordOnly == [.password])

        let cloudOnly = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: .googleDrive,
            authType: .oauth
        )
        #expect(cloudOnly == [.cloudCredentials])

        let drimeTokenOnly = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: .drime,
            authType: .apiKey
        )
        #expect(drimeTokenOnly == [.cloudCredentials])

        let credentialless = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: .local,
            authType: .none
        )
        #expect(credentialless.isEmpty)

        let anonymous = SourcePermanentDeletionPolicy.requiredCredentialStores(
            for: .webdav,
            authType: .none
        )
        #expect(anonymous.isEmpty)
    }

    @Test("Only required credential cleanup can block tombstone removal")
    func onlyRequiredCleanupCanBlockRemoval() {
        #expect(!SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: [.password],
            passwordDeleted: false,
            cloudCredentialsDeleted: true
        ))
        #expect(SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: [.password],
            passwordDeleted: true,
            cloudCredentialsDeleted: false
        ))
        #expect(!SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: [.cloudCredentials],
            passwordDeleted: true,
            cloudCredentialsDeleted: false
        ))
        #expect(SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: [.cloudCredentials],
            passwordDeleted: false,
            cloudCredentialsDeleted: true
        ))
        #expect(SourcePermanentDeletionPolicy.canRemoveTombstone(
            requiredStores: [],
            passwordDeleted: false,
            cloudCredentialsDeleted: false
        ))
    }
}
