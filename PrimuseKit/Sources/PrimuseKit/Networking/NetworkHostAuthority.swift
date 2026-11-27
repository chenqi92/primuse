import Foundation
import Network

/// Host formatting shared by every URL builder and socket probe.
///
/// A bare IPv6 literal cannot be pasted into `"http://\(host):\(port)"`: the
/// tail of the address is parsed as the port, so `URLComponents` either returns
/// a host of `fd7a` or nothing at all. Builders that only guarded with
/// `host.contains(":")` dropped the port instead. Canonicalize once here and let
/// callers ask for the form they need.
public enum NetworkHostAuthority {
    public enum AddressFamily: Sendable, Equatable {
        case ipv4
        case ipv6
        case name
    }

    /// Trims, removes URL brackets and a trailing root dot. The result is the
    /// form sockets and non-HTTP connectors want: a bare literal or hostname.
    public static func canonicalHost(_ rawValue: String) -> String {
        var host = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]"), host.count > 2 {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix("."), host.count > 1 {
            host.removeLast()
        }
        return host
    }

    public static func addressFamily(of rawValue: String) -> AddressFamily {
        let host = canonicalHost(rawValue)
        guard host.isEmpty == false else { return .name }
        if IPv4Address(host) != nil { return .ipv4 }
        // A zone identifier is part of a link-local literal, not of a hostname.
        let literal = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        if IPv6Address(literal) != nil { return .ipv6 }
        return .name
    }

    /// The form that belongs in a URL: IPv6 literals bracketed, everything else
    /// untouched.
    public static func urlHost(_ rawValue: String) -> String {
        let host = canonicalHost(rawValue)
        guard addressFamily(of: host) == .ipv6 else { return host }
        return "[\(host)]"
    }

    /// The bracketed form with the zone identifier escaped, which is what a URL
    /// string and `URLComponents.percentEncodedHost` require: a raw `%` makes
    /// `URLComponents(string:)` return nil, and assigning it to
    /// `percentEncodedHost` traps inside Foundation.
    public static func percentEncodedURLHost(_ rawValue: String) -> String {
        let host = urlHost(rawValue)
        guard host.hasPrefix("["), host.contains("%") else { return host }
        // Idempotent: a zone that already arrived escaped must not be escaped
        // a second time.
        return host
            .replacingOccurrences(of: "%25", with: "%")
            .replacingOccurrences(of: "%", with: "%25")
    }

    /// `host` or `host:port`, with IPv6 brackets applied before the port is
    /// appended.
    public static func authority(host rawHost: String, port: Int?) -> String? {
        let host = percentEncodedURLHost(rawHost)
        guard host.isEmpty == false else { return nil }
        guard let port, (1...65_535).contains(port) else { return host }
        return "\(host):\(port)"
    }

    /// Builds a base URL from the separate fields every connector persists. An
    /// address that already carries a scheme wins over `scheme`, matching the
    /// long-standing behavior of the per-vendor builders.
    public static func baseURL(
        address rawAddress: String,
        defaultScheme: String,
        port: Int?,
        path: String? = nil
    ) -> URL? {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard address.isEmpty == false else { return nil }

        var scheme = defaultScheme
        var remainder = address
        if let separator = remainder.range(of: "://") {
            scheme = String(remainder[..<separator.lowerBound]).lowercased()
            remainder = String(remainder[separator.upperBound...])
        }
        var trailingPath = ""
        if let slash = remainder.firstIndex(of: "/") {
            trailingPath = String(remainder[slash...])
            remainder = String(remainder[..<slash])
        }
        guard remainder.isEmpty == false else { return nil }

        let (host, embeddedPort) = splitHostAndPort(remainder)
        guard let authority = authority(host: host, port: embeddedPort ?? port) else { return nil }

        let resolvedScheme = scheme.isEmpty ? defaultScheme : scheme
        guard var components = URLComponents(string: "\(resolvedScheme)://\(authority)\(trailingPath)") else {
            return nil
        }
        if let path, path.isEmpty == false, path != "/" {
            // The address may already contain escapes; only the separate path
            // field is raw text and needs encoding.
            var suffix = URLComponents()
            suffix.path = path.hasPrefix("/") ? path : "/\(path)"
            let prefix = components.percentEncodedPath
            components.percentEncodedPath = (prefix.hasSuffix("/") ? String(prefix.dropLast()) : prefix)
                + suffix.percentEncodedPath
        }
        return components.url
    }

    /// Splits `host:port`, leaving bracketed and bare IPv6 literals intact.
    public static func splitHostAndPort(_ rawValue: String) -> (host: String, port: Int?) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("[") {
            guard let closing = value.firstIndex(of: "]") else {
                return (canonicalHost(value), nil)
            }
            let host = String(value[value.index(after: value.startIndex)..<closing])
            let tail = value[value.index(after: closing)...]
            guard tail.hasPrefix(":"), let port = Int(tail.dropFirst()) else {
                return (host, nil)
            }
            return (host, port)
        }
        // A bare literal contains several colons; only a single trailing colon
        // can be a port separator.
        let colonCount = value.filter { $0 == ":" }.count
        guard colonCount == 1, let separator = value.lastIndex(of: ":") else {
            return (canonicalHost(value), nil)
        }
        let host = String(value[..<separator])
        guard let port = Int(value[value.index(after: separator)...]) else {
            return (canonicalHost(value), nil)
        }
        return (canonicalHost(host), port)
    }
}
