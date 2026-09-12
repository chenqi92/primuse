import Testing
@testable import PrimuseKit

@Suite("Connector refresh invalidation policy")
struct ConnectorRefreshInvalidationPolicyTests {
    @Test("A forced refresh always tears down the transport")
    func forcedRefreshInvalidates() {
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: "same",
            currentScopeFingerprint: "same",
            forcedByCaller: true
        ))
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: nil,
            currentScopeFingerprint: nil,
            forcedByCaller: true
        ))
    }

    @Test("An unchanged scope keeps the live transport")
    func unchangedScopeKeepsTransport() {
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: "scope-a",
            currentScopeFingerprint: "scope-a",
            forcedByCaller: false
        ) == false)
    }

    @Test("A changed scope tears down the transport")
    func changedScopeInvalidates() {
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: "scope-a",
            currentScopeFingerprint: "scope-b",
            forcedByCaller: false
        ))
    }

    @Test("No cached connector means nothing to rebuild")
    func noCachedConnectorSkipsRebuild() {
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: false,
            cachedConstructionSignature: nil,
            currentConstructionSignature: "construction-b"
        ) == false)
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: false,
            cachedConstructionSignature: "construction-a",
            currentConstructionSignature: "construction-b"
        ) == false)
    }

    @Test("A cached connector built from the same row is kept")
    func unchangedConstructionKeepsConnector() {
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: true,
            cachedConstructionSignature: "construction-a",
            currentConstructionSignature: "construction-a"
        ) == false)
    }

    @Test("A changed construction input rebuilds even when the scope is unchanged")
    func changedConstructionRebuildsConnector() {
        // 加密方式 / 协议版本 / 认证方式 / 设备信任 change the instance but not the
        // byte namespace, so the transport verdict alone would keep a stale one.
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: "scope-a",
            currentScopeFingerprint: "scope-a",
            forcedByCaller: false
        ) == false)
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: true,
            cachedConstructionSignature: "construction-a",
            currentConstructionSignature: "construction-b"
        ))
    }

    @Test("An unprovable cached connector fails closed")
    func unknownConstructionSignatureRebuilds() {
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: true,
            cachedConstructionSignature: nil,
            currentConstructionSignature: "construction-a"
        ))
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: true,
            cachedConstructionSignature: "construction-a",
            currentConstructionSignature: nil
        ))
        #expect(ConnectorRefreshInvalidationPolicy.rebuildsConnector(
            hasCachedConnector: true,
            cachedConstructionSignature: nil,
            currentConstructionSignature: nil
        ))
    }

    @Test("An unobserved fingerprint fails closed")
    func unknownFingerprintInvalidates() {
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: nil,
            currentScopeFingerprint: "scope-a",
            forcedByCaller: false
        ))
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: "scope-a",
            currentScopeFingerprint: nil,
            forcedByCaller: false
        ))
        #expect(ConnectorRefreshInvalidationPolicy.invalidatesTransport(
            previousScopeFingerprint: nil,
            currentScopeFingerprint: nil,
            forcedByCaller: false
        ))
    }
}
