import Foundation
import Network

/// Host-only policy for explicit cleartext HTTP exceptions.
///
/// Local/private addresses keep using the platform's local-network allowance. A
/// public host must be approved explicitly and is matched exactly: trusting
/// `nas.example.com` never grants `other.nas.example.com` or
/// `evil-nas.example.com` access.
public enum InsecureHTTPHostPolicy {
    public static func normalizedHost(_ rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let parsed: String?
        if trimmed.contains("://") {
            parsed = URLComponents(string: trimmed)?.host
        } else if trimmed.filter({ $0 == ":" }).count >= 2,
                  IPv6Address(trimmed.split(separator: "%", maxSplits: 1).first.map(String.init) ?? trimmed) != nil {
            // A bare IPv6 literal must not be fed to `http://\(value)` without
            // brackets because URLComponents interprets its tail as a port.
            parsed = trimmed
        } else if let components = URLComponents(string: "http://\(trimmed)"),
                  components.path.isEmpty || components.path == "/" {
            parsed = components.host
        } else {
            parsed = nil
        }

        guard var host = parsed?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        if host.hasSuffix(".") {
            host.removeLast()
        }
        if let zoneIndex = host.firstIndex(of: "%") {
            host = String(host[..<zoneIndex])
        }
        return host.isEmpty ? nil : host
    }

    public static func isLocalNetworkHost(_ rawValue: String) -> Bool {
        guard let host = normalizedHost(rawValue) else { return false }
        if host == "localhost"
            || host.hasSuffix(".local")
            || host.hasSuffix(".home")
            || host.hasSuffix(".lan")
            || host.hasSuffix(".internal") {
            return true
        }

        return isPrivateIPAddressLiteral(host)
    }

    public static func isPrivateIPAddressLiteral(_ rawValue: String) -> Bool {
        guard let host = normalizedHost(rawValue) else { return false }
        if let ipv6 = IPv6Address(host) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes.dropLast().allSatisfy({ $0 == 0 }) && bytes.last == 1 { return true }
            if (bytes[0] & 0xfe) == 0xfc { return true }
            if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
            return false
        }

        guard let ipv4 = IPv4Address(host) else { return false }
        let bytes = Array(ipv4.rawValue)
        guard bytes.count == 4 else { return false }
        let first = bytes[0]
        let second = bytes[1]
        if first == 10 || first == 127 { return true }
        if first == 172 && (16...31).contains(second) { return true }
        if first == 192 && second == 168 { return true }
        if first == 169 && second == 254 { return true }
        return false
    }

    public static func requiresExplicitTrust(for url: URL) -> Bool {
        guard url.scheme?.lowercased() == "http", let host = url.host else { return false }
        return !isLocalNetworkHost(host)
    }

    public static func matchesExactly(host: String, trustedHost: String) -> Bool {
        guard let normalizedHost = Self.normalizedHost(host),
              let normalizedTrustedHost = Self.normalizedHost(trustedHost) else { return false }
        return normalizedHost == normalizedTrustedHost
    }
}
