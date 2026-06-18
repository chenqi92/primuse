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
        // 同一 domain 的并发请求合并到一次用户决策,共享同一个结果。
        var continuations: [CheckedContinuation<Bool, Never>]
    }

    /// 当前正在向用户征询的请求 (UI 的 `.sslTrustAlert` 绑定它)。
    private(set) var pendingTrustRequest: TrustRequest?

    /// 等待中的请求队列,逐个弹出向用户征询。每个不同 domain 一条。
    private var waitingTrustRequests: [TrustRequest] = []

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
        trustedDomains.contains(Self.normalizeDomain(domain))
    }

    func trust(domain: String) {
        trust(domain: domain, certificateInfo: nil)
    }

    func trust(domain: String, certificateInfo: TrustedCertificateInfo?) {
        let normalized = Self.normalizeDomain(domain)
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
        let normalized = Self.normalizeDomain(domain)
        trustedDomains.removeAll { $0 == normalized }
        trustedCertificates.removeAll { $0.domain == normalized }
        saveToDefaults()
    }

    func certificateInfo(for domain: String) -> TrustedCertificateInfo? {
        let normalized = Self.normalizeDomain(domain)
        return trustedCertificates.first { $0.domain == normalized }
    }

    /// Thread-safe synchronous check for use from URLSession delegate callbacks (non-MainActor).
    /// UserDefaults reads are thread-safe.
    nonisolated static func isTrustedSync(domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        let domains = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        return domains.contains(normalized)
    }

    /// Thread-safe synchronous read of the pinned leaf-certificate SHA256 for a trusted domain.
    /// Returns nil when the domain has no recorded fingerprint yet (TOFU first contact).
    nonisolated static func pinnedFingerprintSync(domain: String) -> String? {
        let normalized = normalizeDomain(domain)
        guard let data = UserDefaults.standard.data(forKey: certificateDefaultsKey),
              let decoded = try? JSONDecoder().decode([TrustedCertificateInfo].self, from: data) else {
            return nil
        }
        return decoded.first { $0.domain == normalized }?.fingerprintSHA256
    }

    /// Show a trust prompt to the user. Returns `true` if user chose to trust the domain.
    /// The UI layer (ContentView) observes `pendingTrustRequest` and shows an alert.
    func requestTrust(domain: String, certificateInfo: TrustedCertificateInfo? = nil) async -> Bool {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return false }
        // Already trusted — no need to ask
        if isTrusted(domain: normalized) { return true }

        return await withCheckedContinuation { continuation in
            // 同一 domain 已在征询 (无论是当前请求还是排队中的),合并到那次决策,
            // 共享同一个用户选择,避免重复弹窗,也避免覆盖丢失旧 continuation。
            if pendingTrustRequest?.domain == normalized {
                pendingTrustRequest?.continuations.append(continuation)
                return
            }
            if let index = waitingTrustRequests.firstIndex(where: { $0.domain == normalized }) {
                waitingTrustRequests[index].continuations.append(continuation)
                return
            }
            let request = TrustRequest(
                domain: normalized,
                certificateInfo: certificateInfo,
                continuations: [continuation]
            )
            if pendingTrustRequest == nil {
                // 没有正在征询的请求,直接展示。
                pendingTrustRequest = request
            } else {
                // 已有不同 domain 在征询,排队等待,不覆盖。
                waitingTrustRequests.append(request)
            }
        }
    }

    /// Record the leaf-certificate fingerprint for an already-trusted domain on first contact (TOFU).
    /// Only fills in a missing pin — never overwrites an existing fingerprint (that path needs user
    /// confirmation via `requestTrustForChangedCertificate`).
    func pinCertificateIfNeeded(domain: String, certificateInfo: TrustedCertificateInfo?) {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return }
        guard certificateInfo?.fingerprintSHA256 != nil else { return }
        if let existing = self.certificateInfo(for: normalized)?.fingerprintSHA256, !existing.isEmpty {
            return
        }
        trust(domain: normalized, certificateInfo: certificateInfo)
    }

    /// Ask the user to re-confirm a trusted domain whose leaf certificate no longer matches the
    /// pinned fingerprint (rotation or interception). Unlike `requestTrust` this does not short-circuit
    /// on the domain already being trusted; on approval it updates the stored fingerprint.
    func requestTrustForChangedCertificate(domain: String, certificateInfo: TrustedCertificateInfo?) async -> Bool {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return false }
        return await withCheckedContinuation { continuation in
            // 同一 domain 已在征询 (无论当前还是排队中),合并到那次决策,共享同一个用户选择。
            if pendingTrustRequest?.domain == normalized {
                pendingTrustRequest?.continuations.append(continuation)
                return
            }
            if let index = waitingTrustRequests.firstIndex(where: { $0.domain == normalized }) {
                waitingTrustRequests[index].continuations.append(continuation)
                return
            }
            let request = TrustRequest(
                domain: normalized,
                certificateInfo: certificateInfo,
                continuations: [continuation]
            )
            if pendingTrustRequest == nil {
                pendingTrustRequest = request
            } else {
                waitingTrustRequests.append(request)
            }
        }
    }

    /// Resume the pending trust request with the user's choice, then present the next queued request.
    func resolveTrustRequest(approved: Bool) {
        guard let request = pendingTrustRequest else { return }
        if approved {
            trust(domain: request.domain, certificateInfo: request.certificateInfo)
        }
        // 先弹出下一个排队请求作为当前请求 (可能为 nil),再 resume 旧的所有 continuation。
        pendingTrustRequest = waitingTrustRequests.isEmpty ? nil : waitingTrustRequests.removeFirst()
        for continuation in request.continuations {
            continuation.resume(returning: approved)
        }
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
        let rawDomains = (UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
            .map(Self.normalizeDomain)
            .filter { !$0.isEmpty }
        // 归一化后去重 (大小写不同的旧条目折叠成同一域名),保留首次出现顺序。
        var seenDomains = Set<String>()
        trustedDomains = rawDomains.filter { seenDomains.insert($0).inserted }

        if let data = UserDefaults.standard.data(forKey: Self.certificateDefaultsKey),
           let decoded = try? JSONDecoder().decode([TrustedCertificateInfo].self, from: data) {
            // 归一化后去重:同一域名只保留一条,优先带指纹/信息更全的那条,避免 ForEach id 冲突。
            var byDomain: [String: TrustedCertificateInfo] = [:]
            var order: [String] = []
            for entry in decoded {
                let normalized = Self.normalizeDomain(entry.domain)
                guard !normalized.isEmpty else { continue }
                let info = TrustedCertificateInfo(
                    domain: normalized,
                    fingerprintSHA256: entry.fingerprintSHA256,
                    expiresAt: entry.expiresAt,
                    subjectSummary: entry.subjectSummary,
                    trustedAt: entry.trustedAt
                )
                if let existing = byDomain[normalized] {
                    byDomain[normalized] = Self.preferredCertificate(existing, info)
                } else {
                    byDomain[normalized] = info
                    order.append(normalized)
                }
            }
            trustedCertificates = order.compactMap { byDomain[$0] }
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
        // 把归一化/去重后的结果写回 UserDefaults,使静态同步路径
        // (isTrustedSync / pinnedFingerprintSync) 读到与内存一致的干净数据。
        saveToDefaults()
    }

    /// 两条同域名证书条目折叠时择优:优先保留带指纹的;都带或都不带时保留较新的。
    nonisolated private static func preferredCertificate(
        _ lhs: TrustedCertificateInfo,
        _ rhs: TrustedCertificateInfo
    ) -> TrustedCertificateInfo {
        let lhsHasPin = !(lhs.fingerprintSHA256?.isEmpty ?? true)
        let rhsHasPin = !(rhs.fingerprintSHA256?.isEmpty ?? true)
        if lhsHasPin != rhsHasPin {
            return lhsHasPin ? lhs : rhs
        }
        return lhs.trustedAt >= rhs.trustedAt ? lhs : rhs
    }

    nonisolated private static func normalizeDomain(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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
            domain: normalizeDomain(domain),
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
                // TOFU 证书钉扎:比对当前 leaf 证书指纹与记录的指纹。
                let info = SSLTrustStore.certificateInfo(domain: domain, trust: trust)
                let currentFingerprint = info?.fingerprintSHA256
                let pinnedFingerprint = SSLTrustStore.pinnedFingerprintSync(domain: domain)
                if pinnedFingerprint == nil {
                    // 首次接触:记录指纹并放行 (TOFU)。
                    await SSLTrustStore.shared.pinCertificateIfNeeded(domain: domain, certificateInfo: info)
                    return (.useCredential, URLCredential(trust: trust))
                }
                if let current = currentFingerprint, current == pinnedFingerprint {
                    // 指纹一致,放行。
                    return (.useCredential, URLCredential(trust: trust))
                }
                // 指纹不一致 (证书轮换/被替换):重新征询用户确认,通过则更新指纹。
                let approved = await SSLTrustStore.shared.requestTrustForChangedCertificate(domain: domain, certificateInfo: info)
                if approved {
                    return (.useCredential, URLCredential(trust: trust))
                }
                return (.cancelAuthenticationChallenge, nil)
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
