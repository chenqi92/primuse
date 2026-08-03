import Testing
@testable import PrimuseKit

@Suite("Source permanent deletion policy")
struct SourcePermanentDeletionPolicyTests {
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
