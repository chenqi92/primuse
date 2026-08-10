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

/// Rebuilds a request only after the server actually returned a redirect.
///
/// This deliberately does not guess an HTTPS endpoint or proactively upgrade
/// HTTP. It only follows redirects accepted by `HTTPRedirectSecurityPolicy`,
/// preserving direct HTTP services while allowing the conventional same-host
/// 80 -> 443 upgrade when the server explicitly requests it.
public enum HTTPRedirectRequestPolicy {
    public static let maximumRedirects = 5

    public static func redirectedRequest(
        from original: URLRequest,
        response: HTTPURLResponse
    ) -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let sourceURL = response.url ?? original.url,
              let location = response.value(forHTTPHeaderField: "Location"),
              let destinationURL = URL(string: location, relativeTo: sourceURL)?.absoluteURL,
              HTTPRedirectSecurityPolicy.allows(from: sourceURL, to: destinationURL) else {
            return nil
        }

        var redirected = original
        redirected.url = destinationURL
        redirected.setValue(nil, forHTTPHeaderField: "Host")

        let method = (original.httpMethod ?? "GET").uppercased()
        let changesToGET = (response.statusCode == 303 && method != "HEAD")
            || ((response.statusCode == 301 || response.statusCode == 302) && method == "POST")
        if changesToGET {
            redirected.httpMethod = "GET"
            redirected.httpBody = nil
            redirected.setValue(nil, forHTTPHeaderField: "Content-Length")
            redirected.setValue(nil, forHTTPHeaderField: "Content-Type")
            redirected.setValue(nil, forHTTPHeaderField: "Transfer-Encoding")
        }
        return redirected
    }
}

/// Follows redirects for read-only media requests without forwarding source
/// credentials to an object-storage or CDN endpoint.
public enum HTTPMediaRedirectRequestPolicy {
    public static let maximumRedirects = HTTPRedirectRequestPolicy.maximumRedirects

    public static func redirectedRequest(
        from original: URLRequest,
        response: HTTPURLResponse
    ) -> URLRequest? {
        guard [301, 302, 303, 307, 308].contains(response.statusCode),
              let sourceURL = response.url ?? original.url,
              let location = response.value(forHTTPHeaderField: "Location"),
              let rawDestinationURL = URL(string: location, relativeTo: sourceURL)?.absoluteURL,
              let sourceEndpoint = NetworkEndpointIdentity(url: sourceURL),
              let rawDestinationEndpoint = NetworkEndpointIdentity(url: rawDestinationURL),
              rawDestinationURL.user == nil,
              rawDestinationURL.password == nil else {
            return nil
        }

        let method = (original.httpMethod ?? "GET").uppercased()
        guard method == "GET" || method == "HEAD" else { return nil }
        guard sourceEndpoint.scheme != "https" || rawDestinationEndpoint.scheme == "https" else {
            return nil
        }

        if HTTPRedirectSecurityPolicy.allows(from: sourceURL, to: rawDestinationURL) {
            return HTTPRedirectRequestPolicy.redirectedRequest(
                from: original,
                response: response
            )
        }

        let destinationURL = upgradedPublicMediaURL(rawDestinationURL)
        var redirected = original
        redirected.url = destinationURL
        redirected.setValue(nil, forHTTPHeaderField: "Host")
        redirected.setValue(nil, forHTTPHeaderField: "Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Proxy-Authorization")
        redirected.setValue(nil, forHTTPHeaderField: "Cookie")
        redirected.setValue(nil, forHTTPHeaderField: "Referer")
        return redirected
    }

    private static func upgradedPublicMediaURL(_ url: URL) -> URL {
        guard url.scheme?.lowercased() == "http",
              let host = url.host,
              !InsecureHTTPHostPolicy.isLocalNetworkHost(host),
              url.port == nil || url.port == 80,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.scheme = "https"
        if components.port == 80 { components.port = nil }
        return components.url ?? url
    }
}
