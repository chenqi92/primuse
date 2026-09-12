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

    @Test("A renewed certificate for the same DNS subject is validated against that name")
    func renewalUsesSharedDNSSubject() {
        #expect(ServerCertificateRenewalPolicy.renewalValidationHostname(
            pinnedSubject: "NAS.example.synology.me",
            currentSubject: " nas.example.synology.me "
        ) == "nas.example.synology.me")
    }

    @Test("A replacement certificate with another subject still needs confirmation")
    func renewalRejectsDifferentSubject() {
        #expect(ServerCertificateRenewalPolicy.renewalValidationHostname(
            pinnedSubject: "nas.example.synology.me",
            currentSubject: "other.example.synology.me"
        ) == nil)
        #expect(ServerCertificateRenewalPolicy.renewalValidationHostname(
            pinnedSubject: nil,
            currentSubject: "nas.example.synology.me"
        ) == nil)
    }

    @Test("Subjects that are not DNS names never qualify for silent renewal")
    func renewalRejectsNonDNSSubjects() {
        #expect(ServerCertificateRenewalPolicy.dnsSubject("192.168.0.50") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("*.synology.me") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("Synology DiskStation") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("localhost") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("nas.local.") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("nas..example.com") == nil)
        #expect(ServerCertificateRenewalPolicy.dnsSubject("nas-01.example.com") == "nas-01.example.com")
    }
}
