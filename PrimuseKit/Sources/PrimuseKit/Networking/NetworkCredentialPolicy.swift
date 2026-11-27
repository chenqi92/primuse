import Foundation

public enum NetworkCredentialPolicy {
    public enum LookupResult: Equatable, Sendable {
        case found(String)
        case notFound
        case temporarilyUnavailable(Int32)
        case failed(Int32)

        public var password: String? {
            guard case .found(let password) = self else { return nil }
            return password
        }
    }

    public enum ConnectorResolution: Equatable, Sendable {
        case ready(String)
        case temporarilyUnavailable(Int32)
        case failed(Int32)
    }

    public static func username(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func password(_ value: String) -> String {
        value
    }

    public static func resolveForConnector(_ lookup: LookupResult) -> ConnectorResolution {
        switch lookup {
        case .found(let password): return .ready(password)
        case .notFound: return .ready("")
        case .temporarilyUnavailable(let status): return .temporarilyUnavailable(status)
        case .failed(let status): return .failed(status)
        }
    }

    /// A replacement credential is eligible for persistence only after the
    /// remote service has accepted it and an authenticated browse request has
    /// succeeded. Until then callers must keep using the last durable value.
    public static func validatedReplacement(
        candidate: String?,
        loginSucceeded: Bool,
        browserReady: Bool
    ) -> String? {
        guard loginSucceeded, browserReady else { return nil }
        return candidate
    }

    /// A failed Keychain lookup can be requested by dozens of artwork rows at
    /// once. Keep that failure briefly so one unavailable credential does not
    /// turn a scrolling view into a tight SecItemCopyMatching retry loop.
    public static let unavailableConnectorRetryDelay: TimeInterval = 5

    public static func shouldReuseUnavailableConnector(
        capturedAt: Date,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(capturedAt) < unavailableConnectorRetryDelay
    }
}
