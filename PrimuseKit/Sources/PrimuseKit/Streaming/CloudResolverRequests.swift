import Foundation

/// A source identifies a stable account even when its access token rotates.
/// Task-local scope survives actor reentrancy without mixing simultaneous sources.
enum CloudResolverRequests {
    struct Account: Sendable {
        let source: MusicSource
        let credential: SourceCredential
    }
    @TaskLocal static var account: Account?

    private static let pool = Pool()
    static func executor(for url: URL, account: Account) -> RequestExecutor {
        pool.executor(for: url, account: account)
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
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { race.install($0) }
        } onCancel: { race.cancel() }
    }

    private final class Pool: @unchecked Sendable {
        private let lock = NSLock()
        private var executors: [String: RequestExecutor] = [:]
        func executor(for url: URL, account: Account) -> RequestExecutor {
            let endpoint = NetworkEndpointIdentity(url: url)?.key ?? url.absoluteString
            let key = endpoint + "|" + account.source.type.rawValue + "|" + account.source.id
            return lock.withLock {
                if let existing = executors[key] { return existing }
                let executor = RequestExecutor(policy: .init(timeout: 60))
                executors[key] = executor
                return executor
            }
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
