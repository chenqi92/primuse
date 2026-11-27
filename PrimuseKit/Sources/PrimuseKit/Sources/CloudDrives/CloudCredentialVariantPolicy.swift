import Foundation

/// Reconciles the local and synchronizable Keychain variants used for cloud
/// OAuth credentials. A rotation is durable only when no obsolete variant can
/// later surface the previous refresh token.
public enum CloudCredentialVariantPolicy {
    /// The target write may be reported as persisted only after the obsolete
    /// variant is gone, has been made an exact mirror, or is a synchronizable
    /// item that this process cannot access and therefore cannot read back.
    public static func isWriteSafe(
        targetStored: Bool,
        obsoleteVariantRemoved: Bool,
        obsoleteVariantMatchesTarget: Bool,
        obsoleteVariantCannotOverrideTarget: Bool
    ) -> Bool {
        targetStored && (
            obsoleteVariantRemoved
                || obsoleteVariantMatchesTarget
                || obsoleteVariantCannotOverrideTarget
        )
    }

    /// When both variants exist during launch migration, modification dates
    /// decide which copy is authoritative. Ties or missing metadata keep the
    /// synchronizable value so a residual legacy/local item can never roll a
    /// newer roaming refresh token back.
    public static func shouldReplaceSynchronizableValue(
        localModifiedAt: Date?,
        synchronizableModifiedAt: Date?
    ) -> Bool {
        guard let localModifiedAt, let synchronizableModifiedAt else { return false }
        return localModifiedAt > synchronizableModifiedAt
    }
}
