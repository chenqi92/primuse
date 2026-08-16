import Foundation
import CryptoKit
import PrimuseKit
import Security
import SwiftUI

/// Serializes the app-wide alert classes that can be raised by background
/// networking. UIKit cannot safely attach two alert controllers to the same
/// presentation hierarchy while one of them is still dismissing.
@MainActor
@Observable
final class AppAlertCoordinator {
    enum Request: Hashable {
        case transport(UUID)
        case sourceAuthentication(String)
        case sourceOperation(String)
        case cellularBackfill
    }

    static let shared = AppAlertCoordinator()

    private(set) var activeRequest: Request?
    private var waitingRequests: [Request] = []
    private var isTransitioning = false
    private var isSuspendedForModal = false
    @ObservationIgnored private var transitionTask: Task<Void, Never>?

    private var transportPresenterStack: [UUID] = []
    private(set) var activeTransportPresenterID: UUID?

    private init() {}

    func enqueue(_ request: Request) {
        guard activeRequest != request, !waitingRequests.contains(request) else { return }
        if activeRequest == nil, !isTransitioning, !isSuspendedForModal {
            activeRequest = request
        } else {
            waitingRequests.append(request)
        }
    }

    func finish(
        _ request: Request,
        suspendAfterDismiss: Bool = false,
        afterDismiss: (@MainActor () -> Void)? = nil
    ) {
        guard activeRequest == request else {
            waitingRequests.removeAll { $0 == request }
            return
        }

        activeRequest = nil
        isTransitioning = true
        transitionTask?.cancel()
        transitionTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self else { return }
            self.isTransitioning = false
            if case .transport = request {
                self.activeTransportPresenterID = self.transportPresenterStack.last
            }
            if suspendAfterDismiss {
                self.isSuspendedForModal = true
            } else {
                self.promoteNextIfPossible()
            }
            afterDismiss?()
        }
    }

    func cancel(_ request: Request) {
        if activeRequest == request {
            finish(request)
        } else {
            waitingRequests.removeAll { $0 == request }
        }
    }

    func resumeAfterModal() {
        isSuspendedForModal = false
        promoteNextIfPossible()
    }

    func registerTransportPresenter(_ id: UUID) {
        transportPresenterStack.removeAll { $0 == id }
        transportPresenterStack.append(id)
        if activeTransportPresenterID == nil || !isPresentingTransportAlert {
            activeTransportPresenterID = id
        }
    }

    func unregisterTransportPresenter(_ id: UUID) {
        transportPresenterStack.removeAll { $0 == id }
        activeTransportPresenterID = transportPresenterStack.last
    }

    private func promoteNextIfPossible() {
        guard activeRequest == nil,
              !isTransitioning,
              !isSuspendedForModal,
              !waitingRequests.isEmpty else {
            return
        }
        activeRequest = waitingRequests.removeFirst()
    }

    private var isPresentingTransportAlert: Bool {
        if case .transport = activeRequest { return true }
        return false
    }
}

/// Manages a set of trusted domains whose SSL certificate errors should be ignored.
/// Persisted to UserDefaults so trust decisions survive app restarts.
@MainActor
@Observable
final class SSLTrustStore {
    static let shared = SSLTrustStore()

    nonisolated private static let defaultsKey = "primuse_trusted_ssl_domains"
    nonisolated private static let certificateDefaultsKey = "primuse_trusted_ssl_certificates_v1"
    nonisolated private static let insecureHTTPDefaultsKey = "primuse_trusted_insecure_http_domains_v1"

    private(set) var trustedDomains: [String] = []
    private(set) var trustedCertificates: [TrustedCertificateInfo] = []
    /// Public hosts the user explicitly allowed for cleartext HTTP. This is
    /// intentionally separate from HTTPS certificate trust so an old SSL
    /// decision can never silently authorize an unencrypted downgrade.
    private(set) var insecureHTTPDomains: [String] = []

    // MARK: - SSL Trust Request (for UI alert flow)

    struct TrustedCertificateInfo: Codable, Equatable, Identifiable, Sendable {
        var id: String { domain }
        let domain: String
        let fingerprintSHA256: String?
        let expiresAt: Date?
        let subjectSummary: String?
        let trustedAt: Date
    }

    private struct TrustWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Bool, Never>
    }

    private struct TrustRequest: Identifiable {
        let id = UUID()
        let domain: String
        let certificateInfo: TrustedCertificateInfo?
        // 同一 domain 的并发请求合并到一次用户决策,共享同一个结果。
        var waiters: [TrustWaiter]
    }

    private struct InsecureHTTPTrustRequest: Identifiable {
        let id = UUID()
        let endpoint: String
        var waiters: [TrustWaiter]
    }

    enum TransportPrompt: Identifiable {
        case certificate(id: UUID, domain: String)
        case insecureHTTP(id: UUID, endpoint: String)

        var id: UUID {
            switch self {
            case .certificate(let id, _), .insecureHTTP(let id, _): id
            }
        }
    }

    /// 当前正在向用户征询的请求 (UI 的 `.sslTrustAlert` 绑定它)。
    private var pendingTrustRequest: TrustRequest?

    /// 等待中的请求队列,逐个弹出向用户征询。每个不同 domain 一条。
    private var waitingTrustRequests: [TrustRequest] = []

    /// Dynamic routes such as FN Connect can reveal their public HTTP endpoint
    /// only after discovery. They use this global queue so the same explicit
    /// warning still applies before the first cleartext request is sent.
    private var pendingInsecureHTTPTrustRequest: InsecureHTTPTrustRequest?
    private var waitingInsecureHTTPTrustRequests: [InsecureHTTPTrustRequest] = []

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
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return false }
        if trustedDomains.contains(normalized) { return true }
        guard let legacyHost = Self.legacyHost(for: normalized) else { return false }
        return trustedDomains.contains(legacyHost)
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
        _ = migrateLegacyCertificateTrustIfNeeded(to: normalized)
        trustedDomains.sort()
        trustedCertificates.sort { $0.domain < $1.domain }
        saveToDefaults()
    }

    func untrust(domain: String) {
        let normalized = Self.normalizeDomain(domain)
        trustedDomains.removeAll { $0 == normalized }
        trustedCertificates.removeAll { $0.domain == normalized }
        saveToDefaults()
    }

    func allowsInsecureHTTP(domain: String) -> Bool {
        guard let normalized = Self.normalizeHTTPTrustTarget(domain) else { return false }
        if insecureHTTPDomains.contains(normalized) { return true }
        guard let legacyHost = Self.legacyHost(for: normalized) else { return false }
        return insecureHTTPDomains.contains(legacyHost)
    }

    func allowInsecureHTTP(domain: String) {
        guard let normalized = Self.normalizeHTTPTrustTarget(domain) else { return }
        let host = Self.legacyHost(for: normalized) ?? normalized
        guard !InsecureHTTPHostPolicy.isLocalNetworkHost(host) else { return }
        var changed = false
        if !insecureHTTPDomains.contains(normalized) {
            insecureHTTPDomains.append(normalized)
            changed = true
        }
        if let legacyHost = Self.legacyHost(for: normalized),
           insecureHTTPDomains.contains(legacyHost) {
            insecureHTTPDomains.removeAll { $0 == legacyHost }
            changed = true
        }
        if changed {
            insecureHTTPDomains.sort()
            saveToDefaults()
        }
    }

    /// Old releases stored one cleartext approval per host. Once that approval
    /// is successfully used for a concrete endpoint, scope it to the exact
    /// HTTP port so it cannot silently authorize another service on that host.
    func migrateLegacyInsecureHTTPTrustIfNeeded(to domain: String) {
        guard let normalized = Self.normalizeHTTPTrustTarget(domain),
              let legacyHost = Self.legacyHost(for: normalized),
              insecureHTTPDomains.contains(legacyHost) else {
            return
        }
        if !insecureHTTPDomains.contains(normalized) {
            insecureHTTPDomains.append(normalized)
        }
        insecureHTTPDomains.removeAll { $0 == legacyHost }
        insecureHTTPDomains.sort()
        saveToDefaults()
    }

    func disallowInsecureHTTP(domain: String) {
        guard let normalized = Self.normalizeHTTPTrustTarget(domain) else { return }
        insecureHTTPDomains.removeAll { $0 == normalized }
        saveToDefaults()
    }

    func requestInsecureHTTPTrust(domain: String) async -> Bool {
        guard let normalized = Self.normalizeHTTPTrustTarget(domain) else { return false }
        if allowsInsecureHTTP(domain: normalized) { return true }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let waiter = TrustWaiter(id: waiterID, continuation: continuation)
                if pendingInsecureHTTPTrustRequest?.endpoint == normalized {
                    pendingInsecureHTTPTrustRequest?.waiters.append(waiter)
                    return
                }
                if let index = waitingInsecureHTTPTrustRequests.firstIndex(where: {
                    $0.endpoint == normalized
                }) {
                    waitingInsecureHTTPTrustRequests[index].waiters.append(waiter)
                    return
                }
                let request = InsecureHTTPTrustRequest(
                    endpoint: normalized,
                    waiters: [waiter]
                )
                if pendingInsecureHTTPTrustRequest == nil {
                    pendingInsecureHTTPTrustRequest = request
                    AppAlertCoordinator.shared.enqueue(.transport(request.id))
                } else {
                    waitingInsecureHTTPTrustRequests.append(request)
                }
            }
        } onCancel: {
            Task { @MainActor in
                SSLTrustStore.shared.cancelInsecureHTTPWaiter(id: waiterID)
            }
        }
    }

    func resolveInsecureHTTPTrustRequest(approved: Bool) {
        guard let request = pendingInsecureHTTPTrustRequest else { return }
        if approved {
            allowInsecureHTTP(domain: request.endpoint)
        }
        let nextRequest = waitingInsecureHTTPTrustRequests.isEmpty
            ? nil
            : waitingInsecureHTTPTrustRequests.removeFirst()
        pendingInsecureHTTPTrustRequest = nextRequest
        AppAlertCoordinator.shared.finish(.transport(request.id))
        if let nextRequest {
            AppAlertCoordinator.shared.enqueue(.transport(nextRequest.id))
        }
        for waiter in request.waiters {
            waiter.continuation.resume(returning: approved)
        }
    }

    private func cancelInsecureHTTPWaiter(id: UUID) {
        if var request = pendingInsecureHTTPTrustRequest,
           let waiterIndex = request.waiters.firstIndex(where: { $0.id == id }) {
            let waiter = request.waiters.remove(at: waiterIndex)
            if request.waiters.isEmpty {
                let nextRequest = waitingInsecureHTTPTrustRequests.isEmpty
                    ? nil
                    : waitingInsecureHTTPTrustRequests.removeFirst()
                pendingInsecureHTTPTrustRequest = nextRequest
                AppAlertCoordinator.shared.cancel(.transport(request.id))
                if let nextRequest {
                    AppAlertCoordinator.shared.enqueue(.transport(nextRequest.id))
                }
            } else {
                pendingInsecureHTTPTrustRequest = request
            }
            waiter.continuation.resume(returning: false)
            return
        }

        guard let requestIndex = waitingInsecureHTTPTrustRequests.firstIndex(where: {
            $0.waiters.contains(where: { $0.id == id })
        }), let waiterIndex = waitingInsecureHTTPTrustRequests[requestIndex].waiters.firstIndex(where: {
            $0.id == id
        }) else { return }
        let waiter = waitingInsecureHTTPTrustRequests[requestIndex].waiters.remove(at: waiterIndex)
        if waitingInsecureHTTPTrustRequests[requestIndex].waiters.isEmpty {
            waitingInsecureHTTPTrustRequests.remove(at: requestIndex)
        }
        waiter.continuation.resume(returning: false)
    }

    func certificateInfo(for domain: String) -> TrustedCertificateInfo? {
        let normalized = Self.normalizeDomain(domain)
        if let exact = trustedCertificates.first(where: { $0.domain == normalized }) {
            return exact
        }
        guard let legacyHost = Self.legacyHost(for: normalized) else { return nil }
        return trustedCertificates.first { $0.domain == legacyHost }
    }

    /// Thread-safe synchronous check for use from URLSession delegate callbacks (non-MainActor).
    /// UserDefaults reads are thread-safe.
    nonisolated static func isTrustedSync(domain: String) -> Bool {
        let normalized = normalizeDomain(domain)
        let domains = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
        if domains.contains(normalized) { return true }
        guard let legacyHost = legacyHost(for: normalized) else { return false }
        return domains.contains(legacyHost)
    }

    /// Thread-safe synchronous check used before bypassing ATS with the
    /// lower-level cleartext HTTP transport.
    nonisolated static func allowsInsecureHTTPHostSync(domain: String) -> Bool {
        guard let normalized = normalizeHTTPTrustTarget(domain) else { return false }
        let domains = UserDefaults.standard.stringArray(forKey: insecureHTTPDefaultsKey) ?? []
        if domains.contains(normalized) { return true }
        guard let legacyHost = legacyHost(for: normalized) else { return false }
        return domains.contains(legacyHost)
    }

    /// Thread-safe synchronous read of the pinned leaf-certificate SHA256 for a trusted domain.
    /// Returns nil when the domain has no recorded fingerprint yet (TOFU first contact).
    nonisolated static func pinnedFingerprintSync(domain: String) -> String? {
        let normalized = normalizeDomain(domain)
        guard let data = UserDefaults.standard.data(forKey: certificateDefaultsKey),
              let decoded = try? JSONDecoder().decode([TrustedCertificateInfo].self, from: data) else {
            return nil
        }
        if let exact = decoded.first(where: { normalizeDomain($0.domain) == normalized }) {
            return exact.fingerprintSHA256
        }
        guard let legacyHost = legacyHost(for: normalized) else { return nil }
        return decoded.first { normalizeDomain($0.domain) == legacyHost }?.fingerprintSHA256
    }

    /// Show a trust prompt to the user. Returns `true` if user chose to trust the domain.
    /// The UI layer (ContentView) observes `pendingTrustRequest` and shows an alert.
    func requestTrust(domain: String, certificateInfo: TrustedCertificateInfo? = nil) async -> Bool {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return false }
        // Already trusted — no need to ask
        if isTrusted(domain: normalized) { return true }

        return await waitForTrustDecision(
            domain: normalized,
            certificateInfo: certificateInfo
        )
    }

    /// Record the leaf-certificate fingerprint for an already-trusted domain on first contact (TOFU).
    /// Only fills in a missing pin — never overwrites an existing fingerprint (that path needs user
    /// confirmation via `requestTrustForChangedCertificate`).
    func pinCertificateIfNeeded(domain: String, certificateInfo: TrustedCertificateInfo?) {
        let normalized = Self.normalizeDomain(domain)
        guard !normalized.isEmpty else { return }
        guard certificateInfo?.fingerprintSHA256 != nil else { return }
        if let existing = trustedCertificates.first(where: { $0.domain == normalized })?.fingerprintSHA256,
           !existing.isEmpty {
            if migrateLegacyCertificateTrustIfNeeded(to: normalized) {
                trustedDomains.sort()
                trustedCertificates.sort { $0.domain < $1.domain }
                saveToDefaults()
            }
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
        return await waitForTrustDecision(
            domain: normalized,
            certificateInfo: certificateInfo
        )
    }

    private func waitForTrustDecision(
        domain: String,
        certificateInfo: TrustedCertificateInfo?
    ) async -> Bool {
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: false)
                    return
                }
                let waiter = TrustWaiter(id: waiterID, continuation: continuation)
                // 同一 domain 的并发请求共享一次决策，但各自保留可取消的 waiter。
                if pendingTrustRequest?.domain == domain {
                    pendingTrustRequest?.waiters.append(waiter)
                    return
                }
                if let index = waitingTrustRequests.firstIndex(where: { $0.domain == domain }) {
                    waitingTrustRequests[index].waiters.append(waiter)
                    return
                }
                let request = TrustRequest(
                    domain: domain,
                    certificateInfo: certificateInfo,
                    waiters: [waiter]
                )
                if pendingTrustRequest == nil {
                    pendingTrustRequest = request
                    AppAlertCoordinator.shared.enqueue(.transport(request.id))
                } else {
                    waitingTrustRequests.append(request)
                }
            }
        } onCancel: {
            Task { @MainActor in
                SSLTrustStore.shared.cancelTrustWaiter(id: waiterID)
            }
        }
    }

    /// Resume the pending trust request with the user's choice, then present the next queued request.
    func resolveTrustRequest(approved: Bool) {
        guard let request = pendingTrustRequest else { return }
        if approved {
            trust(domain: request.domain, certificateInfo: request.certificateInfo)
        }
        let nextRequest = waitingTrustRequests.isEmpty ? nil : waitingTrustRequests.removeFirst()
        pendingTrustRequest = nextRequest
        AppAlertCoordinator.shared.finish(.transport(request.id))
        if let nextRequest {
            AppAlertCoordinator.shared.enqueue(.transport(nextRequest.id))
        }
        for waiter in request.waiters {
            waiter.continuation.resume(returning: approved)
        }
    }

    private func cancelTrustWaiter(id: UUID) {
        if var request = pendingTrustRequest,
           let waiterIndex = request.waiters.firstIndex(where: { $0.id == id }) {
            let waiter = request.waiters.remove(at: waiterIndex)
            if request.waiters.isEmpty {
                let nextRequest = waitingTrustRequests.isEmpty ? nil : waitingTrustRequests.removeFirst()
                pendingTrustRequest = nextRequest
                AppAlertCoordinator.shared.cancel(.transport(request.id))
                if let nextRequest {
                    AppAlertCoordinator.shared.enqueue(.transport(nextRequest.id))
                }
            } else {
                pendingTrustRequest = request
            }
            waiter.continuation.resume(returning: false)
            return
        }

        guard let requestIndex = waitingTrustRequests.firstIndex(where: {
            $0.waiters.contains(where: { $0.id == id })
        }), let waiterIndex = waitingTrustRequests[requestIndex].waiters.firstIndex(where: {
            $0.id == id
        }) else { return }
        let waiter = waitingTrustRequests[requestIndex].waiters.remove(at: waiterIndex)
        if waitingTrustRequests[requestIndex].waiters.isEmpty {
            waitingTrustRequests.remove(at: requestIndex)
        }
        waiter.continuation.resume(returning: false)
    }

    func transportPrompt(id: UUID) -> TransportPrompt? {
        if let request = pendingTrustRequest, request.id == id {
            return .certificate(id: request.id, domain: request.domain)
        }
        if let request = pendingInsecureHTTPTrustRequest, request.id == id {
            return .insecureHTTP(id: request.id, endpoint: request.endpoint)
        }
        return nil
    }

    func resolveTransportPrompt(id: UUID, approved: Bool) {
        if pendingTrustRequest?.id == id {
            resolveTrustRequest(approved: approved)
        } else if pendingInsecureHTTPTrustRequest?.id == id {
            resolveInsecureHTTPTrustRequest(approved: approved)
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
            return NetworkEndpointIdentity(url: url)?.key ?? url.host
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

        let rawHTTPDomains = (UserDefaults.standard.stringArray(forKey: Self.insecureHTTPDefaultsKey) ?? [])
            .compactMap(Self.normalizeHTTPTrustTarget)
            .filter {
                let host = Self.legacyHost(for: $0) ?? $0
                return !InsecureHTTPHostPolicy.isLocalNetworkHost(host)
            }
        var seenHTTPDomains = Set<String>()
        insecureHTTPDomains = rawHTTPDomains.filter { seenHTTPDomains.insert($0).inserted }

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
        insecureHTTPDomains.sort()
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
        if let endpoint = NetworkEndpointIdentity(rawValue: domain) {
            return endpoint.key
        }
        return InsecureHTTPHostPolicy.normalizedHost(domain)
            ?? domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated private static func normalizeHTTPTrustTarget(_ value: String) -> String? {
        if let endpoint = NetworkEndpointIdentity(rawValue: value) {
            guard endpoint.scheme == "http" else { return nil }
            return endpoint.key
        }
        return InsecureHTTPHostPolicy.normalizedHost(value)
    }

    nonisolated private static func legacyHost(for normalizedTarget: String) -> String? {
        NetworkEndpointIdentity(rawValue: normalizedTarget)?.host
    }

    /// Converts a legacy host-wide certificate decision into the endpoint that
    /// just completed a successful pinned handshake. Other ports will ask once
    /// on first use instead of inheriting an unrelated service's certificate.
    private func migrateLegacyCertificateTrustIfNeeded(to normalizedTarget: String) -> Bool {
        guard let legacyHost = Self.legacyHost(for: normalizedTarget) else { return false }
        let hadLegacyDomain = trustedDomains.contains(legacyHost)
        let hadLegacyCertificate = trustedCertificates.contains { $0.domain == legacyHost }
        guard hadLegacyDomain || hadLegacyCertificate else { return false }
        trustedDomains.removeAll { $0 == legacyHost }
        trustedCertificates.removeAll { $0.domain == legacyHost }
        return true
    }

    private func saveToDefaults() {
        UserDefaults.standard.set(trustedDomains, forKey: Self.defaultsKey)
        UserDefaults.standard.set(insecureHTTPDomains, forKey: Self.insecureHTTPDefaultsKey)
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
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
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
final class SmartSSLDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    enum RedirectPolicy: Sendable {
        /// Preserve URLSession's historical redirect behaviour. This remains
        /// the default for artwork, radio, and arbitrary remote media where a
        /// same-service CDN redirect is expected.
        case system
        /// Keep authenticated API traffic on the configured endpoint. A
        /// conventional same-host HTTP-to-HTTPS upgrade is still accepted.
        case sameEndpoint
        /// Permit read-only media redirects to a CDN/object-store endpoint,
        /// while stripping the source's credentials before following it.
        case media
    }

    private let fnMusicRedirects: Bool
    private let httpUsername: String?
    private let httpPassword: String?
    private let httpCredentialEndpoint: NetworkEndpointIdentity?
    private let redirectPolicy: RedirectPolicy
    private let defersUntrustedServerTrustToCaller: Bool

    init(
        fnMusicRedirects: Bool = false,
        httpUsername: String? = nil,
        httpPassword: String? = nil,
        httpCredentialEndpoint: NetworkEndpointIdentity? = nil,
        redirectPolicy: RedirectPolicy = .system,
        defersUntrustedServerTrustToCaller: Bool = false
    ) {
        self.fnMusicRedirects = fnMusicRedirects
        self.httpUsername = httpUsername
        self.httpPassword = httpPassword
        self.httpCredentialEndpoint = httpCredentialEndpoint
        self.redirectPolicy = redirectPolicy
        self.defersUntrustedServerTrustToCaller = defersUntrustedServerTrustToCaller
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await disposition(for: challenge)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        await disposition(for: challenge)
    }

    private func disposition(
        for challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            let host = challenge.protectionSpace.host
            let trustTarget = NetworkEndpointIdentity(
                scheme: challenge.protectionSpace.protocol ?? "https",
                host: host,
                port: challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : nil
            )?.key ?? host
            if SSLTrustStore.isTrustedSync(domain: trustTarget) {
                // TOFU 证书钉扎:比对当前 leaf 证书指纹与记录的指纹。
                let info = SSLTrustStore.certificateInfo(domain: trustTarget, trust: trust)
                let currentFingerprint = info?.fingerprintSHA256
                let pinnedFingerprint = SSLTrustStore.pinnedFingerprintSync(domain: trustTarget)
                if pinnedFingerprint == nil {
                    // 首次接触:记录指纹并放行 (TOFU)。
                    guard let credential = explicitlyTrustedCredential(for: trust) else {
                        return (.cancelAuthenticationChallenge, nil)
                    }
                    scheduleCertificatePin(domain: trustTarget, certificateInfo: info)
                    return (.useCredential, credential)
                }
                if let current = currentFingerprint, current == pinnedFingerprint {
                    // 指纹一致,放行；旧 host-only 记录会在这里按实际端点迁移。
                    guard let credential = explicitlyTrustedCredential(for: trust) else {
                        return (.cancelAuthenticationChallenge, nil)
                    }
                    scheduleCertificatePin(domain: trustTarget, certificateInfo: info)
                    return (.useCredential, credential)
                }
                // 指纹不一致 (证书轮换/被替换):重新征询用户确认,通过则更新指纹。
                if defersUntrustedServerTrustToCaller {
                    return (.performDefaultHandling, nil)
                }
                let approved = await SSLTrustStore.shared.requestTrustForChangedCertificate(
                    domain: trustTarget,
                    certificateInfo: info
                )
                if approved {
                    guard let credential = explicitlyTrustedCredential(for: trust) else {
                        return (.cancelAuthenticationChallenge, nil)
                    }
                    return (.useCredential, credential)
                }
                return (.cancelAuthenticationChallenge, nil)
            }
            var trustError: CFError?
            if SecTrustEvaluateWithError(trust, &trustError) {
                return (.performDefaultHandling, nil)
            }
            if defersUntrustedServerTrustToCaller {
                return (.performDefaultHandling, nil)
            }
            let info = SSLTrustStore.certificateInfo(domain: trustTarget, trust: trust)
            let approved = await SSLTrustStore.shared.requestTrust(domain: trustTarget, certificateInfo: info)
            if approved {
                guard let credential = explicitlyTrustedCredential(for: trust) else {
                    return (.cancelAuthenticationChallenge, nil)
                }
                return (.useCredential, credential)
            }
            return (.cancelAuthenticationChallenge, nil)
        }
        let supportedHTTPMethods: Set<String> = [
            NSURLAuthenticationMethodDefault,
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
        ]
        if supportedHTTPMethods.contains(challenge.protectionSpace.authenticationMethod),
           challenge.previousFailureCount == 0,
           let httpUsername,
           let httpPassword,
           httpCredentialEndpoint == nil || httpCredentialEndpoint == NetworkEndpointIdentity(
               scheme: challenge.protectionSpace.protocol ?? "http",
               host: challenge.protectionSpace.host,
               port: challenge.protectionSpace.port > 0 ? challenge.protectionSpace.port : nil
           ) {
            return (
                .useCredential,
                URLCredential(
                    user: httpUsername,
                    password: httpPassword,
                    persistence: .forSession
                )
            )
        }
        return (.performDefaultHandling, nil)
    }

    /// Convert an endpoint-scoped, fingerprint-checked user decision into a
    /// trust object that Foundation can accept. Newer OS releases no longer
    /// accept a credential whose SecTrust result is still invalid, even when
    /// the URLSession delegate returns `.useCredential`.
    private func explicitlyTrustedCredential(for trust: SecTrust) -> URLCredential? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let leaf = chain.first else {
            return nil
        }

        // The caller has already scoped the decision to the exact
        // scheme/host/port and verified (or just recorded) this leaf's SHA256
        // fingerprint. Re-evaluate it as a server certificate without a DNS
        // name requirement so a NAS reached by LAN IP can use the same
        // certificate as its public hostname. The endpoint pin still prevents
        // another certificate on that IP from being accepted silently.
        let endpointPinnedSSLPolicy = SecPolicyCreateSSL(true, nil)
        guard SecTrustSetPolicies(trust, endpointPinnedSSLPolicy) == errSecSuccess,
              SecTrustSetAnchorCertificates(trust, [leaf] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
            return nil
        }

        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            if let trustError {
                plog("Pinned certificate failed endpoint-scoped SSL evaluation: \(trustError)")
            }
            return nil
        }
        return URLCredential(trust: trust)
    }

    private func scheduleCertificatePin(
        domain: String,
        certificateInfo: SSLTrustStore.TrustedCertificateInfo?
    ) {
        Task { @MainActor in
            SSLTrustStore.shared.pinCertificateIfNeeded(
                domain: domain,
                certificateInfo: certificateInfo
            )
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard fnMusicRedirects else {
            guard redirectPolicy != .system else {
                completionHandler(request)
                return
            }
            if redirectPolicy == .media {
                let redirectCount = Int(task.taskDescription ?? "0") ?? 0
                guard redirectCount < HTTPMediaRedirectRequestPolicy.maximumRedirects,
                      let currentRequest = task.currentRequest ?? task.originalRequest,
                      let redirected = HTTPMediaRedirectRequestPolicy.redirectedRequest(
                          from: currentRequest,
                          response: response
                      ) else {
                    completionHandler(nil)
                    return
                }
                task.taskDescription = String(redirectCount + 1)
                completionHandler(redirected)
                return
            }
            guard let sourceURL = response.url,
                  HTTPRedirectSecurityPolicy.allows(from: sourceURL, to: request.url) else {
                completionHandler(nil)
                return
            }
            completionHandler(request)
            return
        }
        let redirectCount = Int(task.taskDescription ?? "0") ?? 0
        guard redirectCount < FnMusicRedirectPolicy.maximumRedirects,
              let currentRequest = task.currentRequest ?? task.originalRequest else {
            completionHandler(nil)
            return
        }
        task.taskDescription = String(redirectCount + 1)
        completionHandler(
            FnMusicRedirectPolicy.redirectedRequest(
                from: currentRequest,
                to: request
            )
        )
    }

}

private struct TransportTrustAlertsModifier: ViewModifier {
    @State private var presenterID = UUID()

    func body(content: Content) -> some View {
        let store = SSLTrustStore.shared
        let coordinator = AppAlertCoordinator.shared
        let activePrompt: Binding<SSLTrustStore.TransportPrompt?> = Binding(
            get: {
                guard coordinator.activeTransportPresenterID == presenterID,
                      case .transport(let requestID) = coordinator.activeRequest else {
                    return nil
                }
                return store.transportPrompt(id: requestID)
            },
            // Alerts are modal and all actions below resolve the exact
            // request ID. Ignoring SwiftUI's nil write prevents a late
            // dismissal from rejecting the next queued endpoint.
            set: { _, _ in }
        )

        content
            .onAppear {
                coordinator.registerTransportPresenter(presenterID)
            }
            .onDisappear {
                if coordinator.activeTransportPresenterID == presenterID,
                   case .transport(let requestID) = coordinator.activeRequest {
                    store.resolveTransportPrompt(id: requestID, approved: false)
                }
                coordinator.unregisterTransportPresenter(presenterID)
            }
            .alert(item: activePrompt) { prompt in
                switch prompt {
                case .certificate(let id, let domain):
                    return Alert(
                        title: Text("ssl_trust_title"),
                        message: Text("ssl_trust_message \(domain)"),
                        primaryButton: .destructive(Text("trust_domain")) {
                            store.resolveTransportPrompt(id: id, approved: true)
                        },
                        secondaryButton: .cancel(Text("dont_trust")) {
                            store.resolveTransportPrompt(id: id, approved: false)
                        }
                    )
                case .insecureHTTP(let id, let endpoint):
                    return Alert(
                        title: Text("insecure_http_warning_title"),
                        message: Text(String(
                            format: String(localized: "insecure_http_warning_message %@"),
                            endpoint
                        )),
                        primaryButton: .destructive(Text("insecure_http_continue")) {
                            store.resolveTransportPrompt(id: id, approved: true)
                        },
                        secondaryButton: .cancel(Text("cancel")) {
                            store.resolveTransportPrompt(id: id, approved: false)
                        }
                    )
                }
            }
    }
}

extension View {
    func transportTrustAlerts() -> some View {
        modifier(TransportTrustAlertsModifier())
    }
}
