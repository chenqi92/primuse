import Foundation

/// A source tombstone is the retry target for irreversible credential cleanup.
/// It may only be removed after every credential store owned by that source
/// reports success. Unrelated stores must not block deletion: for example, a
/// network share has no OAuth token, while a cloud drive has no source password.
public enum SourcePermanentDeletionPolicy {
    public enum CredentialStore: Hashable, Sendable {
        case password
        case cloudCredentials
    }

    public static func requiredCredentialStores(
        for sourceType: MusicSourceType,
        authType: SourceAuthType
    ) -> Set<CredentialStore> {
        var stores: Set<CredentialStore> = []
        if sourceType.requiresCredentials, authType != .none {
            stores.insert(.password)
        }
        if sourceType.requiresOAuth {
            stores.insert(.cloudCredentials)
        }
        return stores
    }

    public static func canRemoveTombstone(
        requiredStores: Set<CredentialStore>,
        passwordDeleted: Bool,
        cloudCredentialsDeleted: Bool
    ) -> Bool {
        (!requiredStores.contains(.password) || passwordDeleted)
            && (!requiredStores.contains(.cloudCredentials) || cloudCredentialsDeleted)
    }
}
