import CryptoKit
import Foundation

/// Identifies an actual service quota, independently of the feature using it.
public struct RequestQuota: Sendable {
    public struct Account: Hashable, Sendable {
        private let fingerprint: String
        public static let anonymous = Account(fingerprint: "anonymous")

        /// Use a stable account/source identifier, not a rotating bearer token.
        /// Only its digest is retained in the registry.
        public init(stableID: String) {
            fingerprint = SHA256.hash(data: Data(stableID.utf8))
                .map { String(format: "%02x", $0) }.joined()
        }
        private init(fingerprint: String) { self.fingerprint = fingerprint }
    }

    /// One declaration owns a service's status policy and scheduling defaults.
    public struct Service: Sendable {
        public let id: String
        public let policy: RequestExecutor.Policy
        public init(id: String, policy: RequestExecutor.Policy) {
            precondition(!id.isEmpty)
            self.id = id
            self.policy = policy
        }

        public static let appleCatalog = Service(id: "apple.itunes-catalog", policy: .init(
            minimumInterval: 3, maximumConcurrentRequests: 1, timeout: 90,
            rateLimitStatusCodes: [403, 429, 503]
        ))
        /// Conservative application-key pacing shared by Last.fm features.
        public static let lastFM = Service(id: "lastfm.api", policy: .init(
            minimumInterval: 0.2, maximumConcurrentRequests: 1, maximumAttempts: 2, timeout: 15
        ))
        public static let podcast = Service(id: "podcast.http", policy: .init(timeout: 90))
    }

    public let service: Service
    public let endpoint: NetworkEndpointIdentity
    public let account: Account

    public init?(service: Service, url: URL, account: Account = .anonymous) {
        guard let endpoint = NetworkEndpointIdentity(url: url) else { return nil }
        self.service = service
        self.endpoint = endpoint
        self.account = account
    }

    /// Public search/lookup callers spend the same Apple quota. Artwork CDNs,
    /// other ports and arbitrary podcast hosts retain their own status policies.
    public static func appleCatalog(for url: URL) -> RequestQuota? {
        guard let quota = RequestQuota(service: .appleCatalog, url: url),
              quota.endpoint.scheme == "https", quota.endpoint.port == 443,
              quota.endpoint.host == "itunes.apple.com",
              ["/search", "/lookup"].contains(url.path) else { return nil }
        return quota
    }

    fileprivate struct Key: Hashable {
        let service: String
        let endpoint: NetworkEndpointIdentity
        let account: Account
    }
    fileprivate var key: Key { Key(service: service.id, endpoint: endpoint, account: account) }
}

/// Callers share admission and cooldown without retaining private executor pools.
/// Transport, credentials, redirects and response parsing stay in the adapter.
/// At capacity, only idle entries without cooldown or pacing reservations may
/// be evicted. If all entries are protected, new quotas fail with queueFull;
/// existing quotas retain their state and can still accept bounded work.
public actor RequestQuotaRegistry {
    public static let shared = RequestQuotaRegistry()
    public enum ConfigurationError: Error, Sendable { case conflictingPolicy }
    private struct Entry {
        let id = UUID()
        let executor: RequestExecutor
        var leases = 0
        var lastUse: UInt64
    }
    private var entries: [RequestQuota.Key: Entry] = [:]
    private var policies: [String: RequestExecutor.Policy] = [:]
    private var sequence: UInt64 = 0
    private let maximumQuotas: Int
    private let timing: RequestExecutor.Timing

    public init(maximumQuotas: Int = 256, timing: RequestExecutor.Timing = .init()) {
        precondition(maximumQuotas > 0)
        self.maximumQuotas = maximumQuotas
        self.timing = timing
    }

    public func isCoolingDown(for quota: RequestQuota) async -> Bool {
        guard let entry = entries[quota.key] else { return false }
        return await entry.executor.isCoolingDown
    }

    public func execute(
        for quota: RequestQuota, replay: RequestExecutor.Replay = .never,
        timeout: TimeInterval? = nil,
        _ send: @escaping @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        try await withExecutor(for: quota) { executor in
            try await executor.execute(replay: replay, timeout: timeout, send)
        }
    }

    public func execute<Value: Sendable>(
        for quota: RequestQuota, replay: RequestExecutor.Replay = .never,
        timeout: TimeInterval? = nil,
        recover: (@Sendable (Error) async throws -> Bool)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try await withExecutor(for: quota) { executor in
            try await executor.execute(replay: replay, timeout: timeout,
                                       recover: recover, operation: operation)
        }
    }

    private func withExecutor<Value: Sendable>(
        for quota: RequestQuota,
        operation: @Sendable (RequestExecutor) async throws -> Value
    ) async throws -> Value {
        let executor = try await acquire(quota)
        defer {
            entries[quota.key]?.leases -= 1
            sequence &+= 1
            entries[quota.key]?.lastUse = sequence
        }
        return try await operation(executor)
    }

    private func validatePolicy(_ quota: RequestQuota) throws {
        if let policy = policies[quota.service.id], policy != quota.service.policy {
            throw ConfigurationError.conflictingPolicy
        }
    }

    private func acquire(_ quota: RequestQuota) async throws -> RequestExecutor {
        try Task.checkCancellation()
        try validatePolicy(quota)
        if entries[quota.key] == nil && entries.count >= maximumQuotas {
            for (key, candidate) in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
                if entries.count < maximumQuotas || entries[quota.key] != nil { break }
                guard candidate.leases == 0, await candidate.executor.canDiscardQuotaState else { continue }
                // The actor may have admitted a caller while querying the executor.
                guard let current = entries[key], current.id == candidate.id,
                      current.leases == 0, current.lastUse == candidate.lastUse else { continue }
                entries.removeValue(forKey: key)
            }
        }
        try Task.checkCancellation()
        try validatePolicy(quota)
        if var existing = entries[quota.key] {
            existing.leases += 1
            entries[quota.key] = existing
            return existing.executor
        }
        guard entries.count < maximumQuotas else { throw RequestExecutor.AdmissionError.queueFull }
        policies[quota.service.id] = quota.service.policy
        let executor = RequestExecutor(policy: quota.service.policy, timing: timing)
        sequence &+= 1
        entries[quota.key] = Entry(executor: executor, leases: 1, lastUse: sequence)
        return executor
    }
}
