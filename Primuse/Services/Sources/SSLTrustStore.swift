import Foundation

/// Manages a set of trusted domains whose SSL certificate errors should be ignored.
/// Persisted to UserDefaults so trust decisions survive app restarts.
@MainActor
@Observable
final class SSLTrustStore {
    static let shared = SSLTrustStore()

    nonisolated private static let defaultsKey = "primuse_trusted_ssl_domains"

    private(set) var trustedDomains: [String] = []

    // MARK: - SSL Trust Request (for UI alert flow)

    struct TrustRequest: Identifiable {
        let id = UUID()
        let domain: String
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
        guard !trustedDomains.contains(domain) else { return }
        trustedDomains.append(domain)
        trustedDomains.sort()
        saveToDefaults()
    }

    func untrust(domain: String) {
        trustedDomains.removeAll { $0 == domain }
        saveToDefaults()
    }

    /// Thread-safe synchronous check for use from URLSession delegate callbacks (non-MainActor).
    /// UserDefaults reads are thread-safe.
    nonisolated static func isTrustedSync(domain: String) -> Bool {
        let domains = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return domains.contains(domain)
    }

    /// Show a trust prompt to the user. Returns `true` if user chose to trust the domain.
    /// The UI layer (ContentView) observes `pendingTrustRequest` and shows an alert.
    func requestTrust(domain: String) async -> Bool {
        // Already trusted — no need to ask
        if isTrusted(domain: domain) { return true }

        return await withCheckedContinuation { continuation in
            pendingTrustRequest = TrustRequest(domain: domain, continuation: continuation)
        }
    }

    /// Resume the pending trust request with the user's choice.
    func resolveTrustRequest(approved: Bool) {
        guard let request = pendingTrustRequest else { return }
        if approved {
            trust(domain: request.domain)
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
    }

    private func saveToDefaults() {
        UserDefaults.standard.set(trustedDomains, forKey: Self.defaultsKey)
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
        }
        return (.performDefaultHandling, nil)
    }
}
