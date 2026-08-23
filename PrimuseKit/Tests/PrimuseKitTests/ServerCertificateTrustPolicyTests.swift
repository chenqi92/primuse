import Testing
@testable import PrimuseKit

@Suite("Server certificate trust policy")
struct ServerCertificateTrustPolicyTests {
    @Test("System trust wins over a stale manual certificate pin")
    func systemTrustWinsAfterNormalCertificateRenewal() {
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: true,
            endpointWasTrusted: true,
            currentFingerprint: "NEW",
            pinnedFingerprint: "OLD"
        ) == .useSystemTrust)
    }

    @Test("A matching exception pin may handle a system-untrusted certificate")
    func matchingManualPinIsAccepted() {
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: false,
            endpointWasTrusted: true,
            currentFingerprint: "A1B2",
            pinnedFingerprint: "a1b2"
        ) == .usePinnedCertificate)
    }

    @Test("A changed system-untrusted certificate always needs confirmation")
    func changedManualCertificateNeedsConfirmation() {
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: false,
            endpointWasTrusted: true,
            currentFingerprint: "NEW",
            pinnedFingerprint: "OLD"
        ) == .requestChangedCertificateTrust)
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: false,
            endpointWasTrusted: true,
            currentFingerprint: nil,
            pinnedFingerprint: "OLD"
        ) == .requestChangedCertificateTrust)
    }

    @Test("An unknown system-untrusted endpoint needs first-time confirmation")
    func unknownEndpointNeedsInitialConfirmation() {
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: false,
            endpointWasTrusted: false,
            currentFingerprint: "A1B2",
            pinnedFingerprint: nil
        ) == .requestInitialTrust)
    }

    @Test("A legacy trusted endpoint without a pin still needs certificate confirmation")
    func legacyTrustedEndpointNeedsCertificateConfirmation() {
        #expect(ServerCertificateTrustPolicy.action(
            systemTrustSucceeded: false,
            endpointWasTrusted: true,
            currentFingerprint: "A1B2",
            pinnedFingerprint: nil
        ) == .requestInitialTrust)
    }

    @Test("Certificate fingerprints are displayed as uppercase byte pairs")
    func fingerprintFormatting() {
        #expect(ServerCertificateFingerprint.formatted("a1:b2 c3d4") == "A1:B2:C3:D4")
        #expect(ServerCertificateFingerprint.formatted(nil) == nil)
        #expect(ServerCertificateFingerprint.formatted("ABC") == nil)
    }
}
