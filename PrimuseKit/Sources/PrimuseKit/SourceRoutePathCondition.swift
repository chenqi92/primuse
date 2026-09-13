import Foundation
import Network

/// How the active network path relates to a source's private ("内网") route.
///
/// Route selection used to ask only `NWPath.usesInterfaceType(.wifi)` /
/// `.wiredEthernet`. Tailscale, WireGuard and system VPNs are `utun` tunnels
/// that `NWPath` reports as `.other`, so switching one on demoted every private
/// candidate and pushed users who could reach their NAS directly onto the public
/// route instead.
public enum SourceRouteInterfaceClass: String, Sendable, Equatable {
    /// Wi-Fi or wired: the LAN is directly on the path.
    case directLocal
    /// A tunnel interface owns the path. It may carry a tailnet, a corporate
    /// network, or a split tunnel that still reaches the LAN — the interface
    /// type cannot tell, so a private candidate stays eligible.
    case tunnel
    case cellular
    case unavailable
    /// No path observed yet. Keeps the launch-time behavior of trying the
    /// private route first.
    case unknown
}

public struct SourceRoutePathCondition: Sendable, Equatable {
    /// A LAN TCP handshake is a couple of milliseconds; one second has been
    /// enough for direct paths and stays the default.
    public static let directProbeTimeout: TimeInterval = 1
    /// A cold WireGuard tunnel has to complete its own handshake, and a tailnet
    /// peer that cannot be reached directly falls back to a DERP relay. Both
    /// routinely exceed one second on the very first packet.
    public static let tunnelProbeTimeout: TimeInterval = 3
    public static let cellularProbeTimeout: TimeInterval = 2
    public static let unknownProbeTimeout: TimeInterval = 2

    public var interfaceClass: SourceRouteInterfaceClass
    /// A tunnel interface is present even if Wi-Fi is still the primary one.
    /// Split tunnels look like `directLocal` while an overlay peer behind them
    /// is as slow to answer as any tunnel.
    public var usesTunnel: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    /// A tunnel hides what it runs over, and `isExpensive` is not reliably
    /// propagated to `utun`. When a tunnelled path has only cellular underneath
    /// it, metered-network gates must keep treating it as cellular instead of
    /// letting a background backfill run over mobile data.
    public var underlyingCellularOnly: Bool

    public init(
        interfaceClass: SourceRouteInterfaceClass,
        usesTunnel: Bool = false,
        isExpensive: Bool = false,
        isConstrained: Bool = false,
        supportsIPv4: Bool = true,
        supportsIPv6: Bool = true,
        underlyingCellularOnly: Bool = false
    ) {
        self.interfaceClass = interfaceClass
        self.usesTunnel = usesTunnel
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        // A cellular class always implies a metered path, however the value was
        // constructed.
        self.underlyingCellularOnly = underlyingCellularOnly || interfaceClass == .cellular
    }

    public static let unknown = SourceRoutePathCondition(interfaceClass: .unknown)

    /// Whether the private candidate should be attempted before the public one.
    /// It is only an ordering hint now: the router probes the alternatives
    /// concurrently, so a wrong guess costs a head start, not a stalled request.
    public var prefersPrivateRouteFirst: Bool {
        switch interfaceClass {
        case .directLocal, .tunnel, .unknown:
            return true
        case .cellular:
            return usesTunnel
        case .unavailable:
            return false
        }
    }

    public var baseProbeTimeout: TimeInterval {
        switch interfaceClass {
        case .directLocal:
            return usesTunnel ? Self.tunnelProbeTimeout : Self.directProbeTimeout
        case .tunnel:
            return Self.tunnelProbeTimeout
        case .cellular:
            return Self.cellularProbeTimeout
        case .unavailable, .unknown:
            return Self.unknownProbeTimeout
        }
    }

    /// An overlay address needs the tunnel budget even when the path looks like
    /// plain Wi-Fi, which is exactly what a split tunnel reports.
    public func probeTimeout(for endpoint: SourceConnectionEndpoint?) -> TimeInterval {
        guard let host = endpoint?.normalized.host,
              PrivateOverlayHostPolicy.isOverlayHost(host) else {
            return baseProbeTimeout
        }
        return max(baseProbeTimeout, Self.tunnelProbeTimeout)
    }

    /// A tunnel that just came up drops the packet that triggers its own
    /// handshake. One retry turns that into a working route instead of a
    /// 30-second quarantine; paths without a tunnel keep their single attempt.
    public func retriesTimedOutProbe(for endpoint: SourceConnectionEndpoint?) -> Bool {
        if usesTunnel || interfaceClass == .tunnel { return true }
        guard let host = endpoint?.normalized.host else { return false }
        return PrivateOverlayHostPolicy.isOverlayHost(host)
    }

    /// An address literal of a family the path does not carry can be rejected
    /// without spending the probe budget. Only literals: a hostname on an
    /// IPv6-only carrier still resolves through DNS64/NAT64.
    public func canProbeAddressFamily(of endpoint: SourceConnectionEndpoint?) -> Bool {
        guard let host = endpoint?.normalized.host else { return true }
        switch NetworkHostAuthority.addressFamily(of: host) {
        case .ipv4: return supportsIPv4
        case .ipv6: return supportsIPv6
        case .name: return true
        }
    }
}

public extension SourceRoutePathCondition {
    init(path: NWPath) {
        let satisfied = path.status == .satisfied
        let usesTunnel = path.usesInterfaceType(.other)
        let interfaceClass: SourceRouteInterfaceClass
        if satisfied == false {
            interfaceClass = .unavailable
        } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            interfaceClass = .directLocal
        } else if usesTunnel {
            interfaceClass = .tunnel
        } else if path.usesInterfaceType(.cellular) {
            interfaceClass = .cellular
        } else {
            interfaceClass = .unknown
        }
        let available = path.availableInterfaces
        let hasCellular = available.contains { $0.type == .cellular }
        let hasDirectLocal = available.contains {
            $0.type == .wifi || $0.type == .wiredEthernet
        }
        self.init(
            interfaceClass: interfaceClass,
            usesTunnel: usesTunnel,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained,
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            underlyingCellularOnly: interfaceClass == .cellular
                || (usesTunnel && hasCellular && hasDirectLocal == false)
        )
    }
}

/// Why a route was retired. Only used to size the private-route cooldown: a
/// refused connection is durable evidence, a timeout usually is not.
public enum SourceRouteFailureReason: String, Sendable, Equatable {
    case timedOut
    case refused

    public static func classify(_ error: any Error) -> SourceRouteFailureReason {
        classify(error, depth: 0)
    }

    private static func classify(_ error: any Error, depth: Int) -> SourceRouteFailureReason {
        guard depth < 8 else { return .refused }
        if let networkError = error as? NWError {
            if case .posix(let code) = networkError {
                return Int(code.rawValue) == Int(ETIMEDOUT) ? .timedOut : .refused
            }
            // A name that only resolves inside the tunnel fails to resolve while
            // the tunnel is still coming up.
            if case .dns = networkError { return .timedOut }
            return .refused
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            switch URLError.Code(rawValue: nsError.code) {
            case .timedOut, .cannotFindHost, .dnsLookupFailed:
                return .timedOut
            default:
                break
            }
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ETIMEDOUT) {
            return .timedOut
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? any Error {
            return classify(underlying, depth: depth + 1)
        }
        return .refused
    }
}
