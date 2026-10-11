import Foundation
import PrimuseKit

/// Stable quota ownership across manual, background and settings callers.
/// RequestExecutor alone owns admission, pacing and server cooldown deadlines.
actor ScraperRequestPool {
    static let shared = ScraperRequestPool()

    enum Key: Hashable, Sendable {
        case custom(String)
        case lyricsServer(String)
        case resource(String)
    }

    private var executors: [Key: RequestExecutor] = [:]
    private let timing: RequestExecutor.Timing

    init(timing: RequestExecutor.Timing = .init()) { self.timing = timing }

    func executor(for key: Key) -> RequestExecutor {
        if let existing = executors[key] { return existing }
        // 节奏靠每次调用的请求间隔, 并发和以前一样允许重叠: 手动刮削页的缩略图不必逐张排队。
        let executor = RequestExecutor(policy: .init(maximumConcurrentRequests: 4), timing: timing)
        executors[key] = executor
        return executor
    }

    func isCoolingDown(for key: Key) async -> Bool {
        guard let executor = executors[key] else { return false }
        return await executor.isCoolingDown
    }

    nonisolated static func resourceKey(source: ScraperSourceConfig?, url: URL? = nil) -> Key {
        if case .custom(let id) = source?.type { return .custom(id) }
        // Built-in image CDNs do not inherit API-specific statuses (e.g. iTunes 403).
        return .resource(source?.type.rawValue ?? url?.host?.lowercased() ?? "unknown")
    }

    nonisolated static func lyricsKey(_ address: String) -> Key {
        guard var url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return .lyricsServer(address)
        }
        url.scheme = url.scheme?.lowercased()
        url.host = url.host?.lowercased()
        if (url.scheme == "https" && url.port == 443) || (url.scheme == "http" && url.port == 80) {
            url.port = nil
        }
        url.fragment = nil
        if url.path.isEmpty == true { url.path = "/" }
        return .lyricsServer(url.string ?? address)
    }

    nonisolated static func scraperError(_ error: Error) -> Error {
        if let failure = error as? HTTPResponseFailure {
            if failure.statusCode == 429 || failure.statusCode == 503 {
                return ScraperError.rateLimited(retryAfter: failure.retryAfter.map {
                    $0.rounded(.up).finiteInt(or: Int.max)
                })
            }
            return ScraperError.networkError("HTTP \(failure.statusCode)")
        }
        if error is RequestExecutor.AdmissionError { return ScraperError.busy }
        return error
    }
}
