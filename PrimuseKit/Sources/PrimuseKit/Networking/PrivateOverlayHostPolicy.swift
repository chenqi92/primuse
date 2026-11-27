import Foundation
import Network

/// Recognizes addresses that only exist inside a private overlay network —
/// Tailscale, ZeroTier, WireGuard meshes.
///
/// These are neither reachable from the Internet nor RFC 1918 private, so the
/// existing `InsecureHTTPHostPolicy` classification called them public. That is
/// what made routing treat a tailnet NAS as a WAN server, and it is why the
/// IPv4 and IPv6 sides of the same tailnet behaved differently: Tailscale's
/// `fd7a:115c:a1e0::/48` already matched the `fc00::/7` ULA rule while its
/// `100.64.0.0/10` IPv4 counterpart did not.
///
/// Deliberately *not* used for TLS trust or for the AI provider's cleartext
/// allowance. A carrier-grade NAT address can also appear on a hostile mobile
/// network, so certificate acceptance keeps requiring the explicit per-endpoint
/// confirmation rather than becoming automatic here.
public enum PrivateOverlayHostPolicy {
    /// MagicDNS names. Tailscale owns the suffix, so it can never be a public
    /// server the user reaches over the Internet.
    public static let overlayDomainSuffixes = [".ts.net"]

    public static func isOverlayHost(_ rawValue: String) -> Bool {
        guard let host = InsecureHTTPHostPolicy.normalizedHost(rawValue) else { return false }
        if overlayDomainSuffixes.contains(where: { host.hasSuffix($0) }) { return true }

        if let ipv6 = IPv6Address(NetworkHostAuthority.canonicalHost(host)) {
            let bytes = Array(ipv6.rawValue)
            guard bytes.count == 16 else { return false }
            // Tailscale's ULA prefix. Kept explicit so the intent survives even
            // if the generic ULA rule is ever narrowed.
            return bytes[0] == 0xfd && bytes[1] == 0x7a && bytes[2] == 0x11 && bytes[3] == 0x5c
        }

        guard let ipv4 = IPv4Address(host) else { return false }
        let bytes = Array(ipv4.rawValue)
        guard bytes.count == 4 else { return false }
        // RFC 6598 shared address space, 100.64.0.0/10.
        return bytes[0] == 100 && (64...127).contains(bytes[1])
    }

    /// True for anything that can only be reached from inside the user's own
    /// network, whether that is the LAN or an overlay on top of it.
    public static func isPrivateOrOverlayHost(_ rawValue: String) -> Bool {
        InsecureHTTPHostPolicy.isLocalNetworkHost(rawValue) || isOverlayHost(rawValue)
    }
}
