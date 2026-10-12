import Foundation

/// A source identifies a stable account even when its access token rotates.
/// Task-local scope survives actor reentrancy without mixing simultaneous sources.
struct CloudResolverRequests: Sendable {
    struct Account: Sendable {
        let source: MusicSource
        let credential: SourceCredential
    }
    @TaskLocal static var account: Account?

    let registry: RequestQuotaRegistry

    private static func service(id: String, interval: TimeInterval) -> RequestQuota.Service {
        .init(id: id, policy: .init(minimumInterval: interval, maximumConcurrentRequests: 6,
            maximumAttempts: 5, maximumRetryWait: 8, timeout: 3600,
            rateLimitStatusCodes: [429], defaultCooldown: 2))
    }
    private static let cloud = service(id: "cloud.resolver", interval: 0)
    private static let baidu = service(id: "cloud.resolver.baidu", interval: 0.1)
    private static let guangyaList = service(id: "cloud.resolver.guangya.list", interval: GuangYaAPIProtocol.fileListMinimumInterval)
    private static let guangyaBusiness = service(id: "cloud.resolver.guangya.business", interval: GuangYaAPIProtocol.defaultMinimumInterval)

    func execute<Value: Sendable>(url: URL, account: Account,
        replay: RequestExecutor.Replay = .never,
        recover: (@Sendable (Error) async throws -> Bool)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let service: RequestQuota.Service
        let owner: RequestQuota.Account
        if url.host == "openapi.guangyapan.com" {
            service = url.path.hasSuffix(GuangYaAPIProtocol.fileListPath) ? Self.guangyaList : Self.guangyaBusiness
            owner = .anonymous // GuangYa limits an IP, independently of accounts.
        } else {
            service = url.host == "pan.baidu.com" ? Self.baidu : Self.cloud
            let identity = account.source.cloudAccountID.map { "account:" + $0 } ?? "source:" + account.source.id
            owner = .init(stableID: account.source.type.rawValue + "|" + identity)
        }
        guard let quota = RequestQuota(service: service, url: url, account: owner) else { throw URLError(.badURL) }
        return try await registry.execute(for: quota, replay: replay, timeout: 60, recover: recover, operation: operation)
    }

    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let failure = error as? HTTPResponseFailure {
            return [401, 403].contains(failure.statusCode) && failure.retryAfter == nil && !failure.isRateLimited
        }
        return error as? StreamResolveError == .authFailed
    }

    static func validate(_ data: Data, response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200...299).contains(http.statusCode) else {
            throw HTTPResponseFailure(statusCode: http.statusCode, body: data,
                retryAfter: HTTPResponseFailure.retryDelay(from: http))
        }
        return http
    }

    /// Cancelling one caller must not cancel a refresh shared by other callers.
    static func wait<Value: Sendable>(for task: Task<Value, Error>) async throws -> Value {
        let race = CancellableResultRace<Value>()
        Task {
            do { race.resolve(.success(try await task.value)) }
            catch { race.resolve(.failure(error)) }
        }
        do {
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { race.install($0) }
            } onCancel: { race.cancel() }
        } catch {
            try Task.checkCancellation()
            // Invalidating a shared credential task is not cancellation of its
            // caller. Let playback leave its loading state and show an auth
            // error, without restarting refresh using the old credentials.
            if task.isCancelled { throw URLError(.userAuthenticationRequired) }
            throw error
        }
    }
}

actor CloudResolverReadAttempt {
    private var recovered = false
    private(set) var token: String?
    func record(token: String) { self.token = token }
    func claimRecovery() -> Bool {
        guard !recovered else { return false }
        recovered = true
        return true
    }
}
