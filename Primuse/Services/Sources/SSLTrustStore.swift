import Foundation
import CryptoKit
import Security

/// Manages a set of trusted domains whose SSL certificate errors should be ignored.
/// Persisted to UserDefaults so trust decisions survive app restarts.
@MainActor
@Observable
final class SSLTrustStore {
    static let shared = SSLTrustStore()

    nonisolated private static let defaultsKey = "primuse_trusted_ssl_domains"
    nonisolated private static let certificateDefaultsKey = "primuse_trusted_ssl_certificates_v1"

    private(set) var trustedDomains: [String] = []
    private(set) var trustedCertificates: [TrustedCertificateInfo] = []

    // MARK: - SSL Trust Request (for UI alert flow)

    struct TrustedCertificateInfo: Codable, Equatable, Identifiable, Sendable {
        var id: String { domain }
        let domain: String
        let fingerprintSHA256: String?
        let expiresAt: Date?
        let subjectSummary: String?
        let trustedAt: Date
    }

    struct TrustRequest: Identifiable {
        let id = UUID()
        let domain: String
        let certificateInfo: TrustedCertificateInfo?
        let continuation: CheckedContinuation<Bool, Never>
    }

    var pendingTrustRequest: TrustRequest?

    private static let defaultDomains: [String] = []

    private init() {
        loadFromDefaults()
        seedDefaultsIfNeeded()
    }

    private func seedDefaultsIfNeeded() {
        let seededKey = "primuse_ssl_defaults_seeded"
        guard !UserDefaults.standard.bool(forKey: seededKey) else { return }
        for domain in Self.defaultDomains {
            if !trustedDomains.contains(domain) {
                trustedDomains.append(domain)
            }
        }
        trustedDomains.sort()
        saveToDefaults()
        UserDefaults.standard.set(true, forKey: seededKey)
    }

    // MARK: - Public API

    func isTrusted(domain: String) -> Bool {
        trustedDomains.contains(domain)
    }

    func trust(domain: String) {
        trust(domain: domain, certificateInfo: nil)
    }

    func trust(domain: String, certificateInfo: TrustedCertificateInfo?) {
        let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return }
        if !trustedDomains.contains(normalized) {
            trustedDomains.append(normalized)
        }
        trustedDomains.sort()
        let info = certificateInfo.map {
            TrustedCertificateInfo(
                domain: normalized,
                fingerprintSHA256: $0.fingerprintSHA256,
                expiresAt: $0.expiresAt,
                subjectSummary: $0.subjectSummary,
                trustedAt: $0.trustedAt
            )
        } ?? TrustedCertificateInfo(
            domain: normalized,
            fingerprintSHA256: nil,
            expiresAt: nil,
            subjectSummary: nil,
            trustedAt: Date()
        )
        if let index = trustedCertificates.firstIndex(where: { $0.domain == normalized }) {
            trustedCertificates[index] = info
        } else {
            trustedCertificates.append(info)
        }
        trustedCertificates.sort { $0.domain < $1.domain }
        saveToDefaults()
    }

    func untrust(domain: String) {
        trustedDomains.removeAll { $0 == domain }
        trustedCertificates.removeAll { $0.domain == domain }
        saveToDefaults()
    }

    func certificateInfo(for domain: String) -> TrustedCertificateInfo? {
        trustedCertificates.first { $0.domain == domain }
    }

    /// Thread-safe synchronous check for use from URLSession delegate callbacks (non-MainActor).
    /// UserDefaults reads are thread-safe.
    nonisolated static func isTrustedSync(domain: String) -> Bool {
        let domains = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return domains.contains(domain)
    }

    /// Show a trust prompt to the user. Returns `true` if user chose to trust the domain.
    /// The UI layer (ContentView) observes `pendingTrustRequest` and shows an alert.
    func requestTrust(domain: String, certificateInfo: TrustedCertificateInfo? = nil) async -> Bool {
        // Already trusted — no need to ask
        if isTrusted(domain: domain) { return true }

        return await withCheckedContinuation { continuation in
            pendingTrustRequest = TrustRequest(
                domain: domain,
                certificateInfo: certificateInfo,
                continuation: continuation
            )
        }
    }

    /// Resume the pending trust request with the user's choice.
    func resolveTrustRequest(approved: Bool) {
        guard let request = pendingTrustRequest else { return }
        if approved {
            trust(domain: request.domain, certificateInfo: request.certificateInfo)
        }
        pendingTrustRequest = nil
        request.continuation.resume(returning: approved)
    }

    // MARK: - SSL Error Detection

    /// Returns the domain if the error is an SSL certificate error, otherwise nil.
    nonisolated static func sslErrorDomain(from error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return nil }
        let sslCodes: Set<Int> = [
            NSURLErrorServerCertificateUntrusted,
            NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot,
            NSURLErrorServerCertificateNotYetValid,
            NSURLErrorSecureConnectionFailed,
        ]
        guard sslCodes.contains(nsError.code) else { return nil }
        // Try to extract the domain from the error's userInfo or failing URL
        if let url = nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            return url.host
        }
        return nil
    }

    /// Check if an error is SSL-related and prompt user to trust if so.
    /// Returns true if user trusted the domain (caller should retry).
    /// NOTE: This uses pendingTrustRequest which requires the alert to be visible.
    /// For views presented as sheets, use the .sslTrustAlert() modifier instead.
    @discardableResult
    func handleSSLErrorIfNeeded(_ error: Error) async -> Bool {
        guard let domain = Self.sslErrorDomain(from: error) else { return false }
        return await requestTrust(domain: domain)
    }

    // MARK: - Persistence

    private func loadFromDefaults() {
        trustedDomains = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        if let data = UserDefaults.standard.data(forKey: Self.certificateDefaultsKey),
           let decoded = try? JSONDecoder().decode([TrustedCertificateInfo].self, from: data) {
            trustedCertificates = decoded
        }
        let domainsWithInfo = Set(trustedCertificates.map(\.domain))
        for domain in trustedDomains where !domainsWithInfo.contains(domain) {
            trustedCertificates.append(TrustedCertificateInfo(
                domain: domain,
                fingerprintSHA256: nil,
                expiresAt: nil,
                subjectSummary: nil,
                trustedAt: Date.distantPast
            ))
        }
        trustedDomains.sort()
        trustedCertificates.sort { $0.domain < $1.domain }
    }

    private func saveToDefaults() {
        UserDefaults.standard.set(trustedDomains, forKey: Self.defaultsKey)
        if let data = try? JSONEncoder().encode(trustedCertificates) {
            UserDefaults.standard.set(data, forKey: Self.certificateDefaultsKey)
        }
    }

    nonisolated static func certificateInfo(domain: String, trust: SecTrust) -> TrustedCertificateInfo? {
        guard let certificate = leafCertificate(from: trust) else { return nil }
        let data = SecCertificateCopyData(certificate) as Data
        let fingerprint = SHA256.hash(data: data)
            .map { String(format: "%02X", $0) }
            .joined()
        return TrustedCertificateInfo(
            domain: domain.lowercased(),
            fingerprintSHA256: fingerprint,
            expiresAt: certificateExpiry(certificate),
            subjectSummary: SecCertificateCopySubjectSummary(certificate) as String?,
            trustedAt: Date()
        )
    }

    nonisolated private static func leafCertificate(from trust: SecTrust) -> SecCertificate? {
        if #available(macOS 12.0, iOS 15.0, *) {
            return (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        }
        return SecTrustGetCertificateAtIndex(trust, 0)
    }

    nonisolated private static func certificateExpiry(_ certificate: SecCertificate) -> Date? {
#if os(macOS)
        let keys = [kSecOIDX509V1ValidityNotAfter] as CFArray
        guard
            let values = SecCertificateCopyValues(certificate, keys, nil) as? [String: Any],
            let entry = values[kSecOIDX509V1ValidityNotAfter as String] as? [String: Any]
        else { return nil }
        return entry[kSecPropertyKeyValue as String] as? Date
#else
        return nil
#endif
    }
}

// MARK: - Smart SSL Delegate

/// URLSession delegate that only bypasses SSL validation for domains in the trust store.
/// For untrusted domains, uses the system's default certificate validation.
final class SmartSSLDelegate: NSObject, URLSessionDelegate, Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let domain = challenge.protectionSpace.host
            if SSLTrustStore.isTrustedSync(domain: domain) {
                return (.useCredential, URLCredential(trust: trust))
            }
            var trustError: CFError?
            if SecTrustEvaluateWithError(trust, &trustError) {
                return (.performDefaultHandling, nil)
            }
            let info = SSLTrustStore.certificateInfo(domain: domain, trust: trust)
            let approved = await SSLTrustStore.shared.requestTrust(domain: domain, certificateInfo: info)
            if approved {
                return (.useCredential, URLCredential(trust: trust))
            }
            return (.cancelAuthenticationChallenge, nil)
        }
        return (.performDefaultHandling, nil)
    }
}
