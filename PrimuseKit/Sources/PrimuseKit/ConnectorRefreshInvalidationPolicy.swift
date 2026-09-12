import Foundation

/// An edit sheet completion refreshes the connector for every save, including
/// renames and display-only changes. Only a save that actually moved the
/// account/endpoint security scope may tear down a live transport, so the
/// refresh consults the same scope fingerprint the source-row notification
/// path already trusts.
public enum ConnectorRefreshInvalidationPolicy {
    /// Whether live streaming sessions must be cancelled and previously
    /// downloaded bytes distrusted. Only the account/endpoint/credential scope
    /// answers that question.
    public static func invalidatesTransport(
        previousScopeFingerprint: String?,
        currentScopeFingerprint: String?,
        forcedByCaller: Bool
    ) -> Bool {
        if forcedByCaller { return true }
        switch SourceConfigurationInvalidationPolicy.action(
            previousScopeFingerprint: previousScopeFingerprint,
            currentScopeFingerprint: currentScopeFingerprint
        ) {
        case .ignoreNonSecurityChange:
            return false
        case .invalidateSecurityScope:
            return true
        }
    }

    /// Whether a cached connector instance still matches the source row.
    /// The scope fingerprint deliberately excludes fields that do not change
    /// the byte namespace but are baked into the connector when it is built
    /// (transport encryption, protocol version, auth type, device trust,
    /// type-specific configuration), so a separate construction signature
    /// decides this. An unknown signature on a cached instance fails closed:
    /// a connector that cannot be proven current is rebuilt.
    public static func rebuildsConnector(
        hasCachedConnector: Bool,
        cachedConstructionSignature: String?,
        currentConstructionSignature: String?
    ) -> Bool {
        guard hasCachedConnector else { return false }
        guard let cachedConstructionSignature,
              let currentConstructionSignature else { return true }
        return cachedConstructionSignature != currentConstructionSignature
    }
}
