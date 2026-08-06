import Foundation

/// Canonical identity for transport-security decisions.
///
/// The scheme and effective port are part of the identity so trusting an
/// HTTPS certificate on one service port does not silently trust a different
/// service, and allowing cleartext HTTP never authorizes HTTPS downgrade (or
/// the reverse). Paths and query items deliberately do not affect trust.
public struct NetworkEndpointIdentity: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init?(url: URL) {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        self.init(scheme: scheme, host: host, port: url.port)
    }

    public init?(scheme rawScheme: String, host rawHost: String, port rawPort: Int? = nil) {
        let scheme = rawScheme.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard scheme == "http" || scheme == "https",
              let host = InsecureHTTPHostPolicy.normalizedHost(rawHost) else { return nil }

        let port = rawPort ?? Self.defaultPort(for: scheme)
        guard (1...65_535).contains(port) else { return nil }

        self.scheme = scheme
        self.host = host
        self.port = port
    }

    public init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("://"),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    public var key: String {
        let formattedHost = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(formattedHost):\(port)"
    }

    public static func defaultPort(for scheme: String) -> Int {
        scheme.lowercased() == "https" ? 443 : 80
    }
}

/// Redirects may change only the path/query on the configured endpoint. The
/// sole cross-endpoint exception is the conventional same-host HTTP-to-HTTPS
/// upgrade (80 to 443); HTTPS downgrades and custom-port hops are rejected.
public enum HTTPRedirectSecurityPolicy {
    public static func allows(from source: URL, to destination: URL?) -> Bool {
        guard let destination,
              let sourceEndpoint = NetworkEndpointIdentity(url: source),
              let destinationEndpoint = NetworkEndpointIdentity(url: destination),
              sourceEndpoint.host == destinationEndpoint.host else {
            return false
        }
        if sourceEndpoint.scheme == destinationEndpoint.scheme {
            return sourceEndpoint.port == destinationEndpoint.port
        }
        return sourceEndpoint.scheme == "http"
            && destinationEndpoint.scheme == "https"
            && sourceEndpoint.port == 80
            && destinationEndpoint.port == 443
    }
}
