import Foundation

/// Media-server API quotas survive connector and session recreation. The
/// caller supplies the stable account identity; credentials never enter logs.
/// Authentication, response bounds, trust and redirects remain in the transport.
public final class ServerRequestScheduler: @unchecked Sendable {
    public static let shared = ServerRequestScheduler()
    private let lock = NSLock()
    private var executors: [String: RequestExecutor] = [:]
    private let timing: RequestExecutor.Timing

    public init(timing: RequestExecutor.Timing = .init()) { self.timing = timing }

    public func executor(baseURL: URL, account: String) -> RequestExecutor {
        let endpoint = NetworkEndpointIdentity(url: baseURL)?.key ?? baseURL.absoluteString
        let key = endpoint + "|" + baseURL.path + "|" + account
        return lock.withLock {
            if let existing = executors[key] { return existing }
            let executor = RequestExecutor(policy: .init(timeout: 60), timing: timing)
            executors[key] = executor
            return executor
        }
    }
}
