import Foundation

/// Resolves Keychain lookup results for Scrobble providers without treating a
/// read failure as a definitively missing token. Providers whose credentials
/// are temporarily unreadable remain eligible for the durable retry queue;
/// providers that are definitively unconfigured do not create new queue rows.
public enum ScrobbleCredentialAvailabilityPolicy {
    public enum ValueResolution: Equatable, Sendable {
        case ready(String)
        case notConfigured
        case unavailable
    }

    public enum ProviderResolution: Equatable, Sendable {
        case ready
        case notConfigured
        case unavailable
    }

    public static func resolveValue(
        _ lookup: NetworkCredentialPolicy.LookupResult,
        fallback: String = ""
    ) -> ValueResolution {
        switch lookup {
        case .found(let value):
            if !value.isEmpty { return .ready(value) }
            return fallback.isEmpty ? .notConfigured : .ready(fallback)
        case .notFound:
            return fallback.isEmpty ? .notConfigured : .ready(fallback)
        case .temporarilyUnavailable, .failed:
            return .unavailable
        }
    }

    public static func resolveProvider(
        _ values: [ValueResolution]
    ) -> ProviderResolution {
        guard !values.isEmpty else { return .notConfigured }
        if values.contains(.unavailable) { return .unavailable }
        if values.allSatisfy({
            if case .ready = $0 { return true }
            return false
        }) {
            return .ready
        }
        return .notConfigured
    }

    public static func shouldQueue(_ resolution: ProviderResolution) -> Bool {
        resolution == .ready || resolution == .unavailable
    }
}
