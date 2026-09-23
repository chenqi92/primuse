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
    /// A public address has to be resolved and then reached across the
    /// Internet. A DDNS name whose only record is an AAAA is the slowest case:
    /// the lookup happens before the first SYN and there is no second address
    /// family to fall back to. One second is a LAN budget, and applying it to a
    /// public route retired an endpoint whose own handshake is allowed twenty
    /// seconds (`SourceConnectionHandshakePolicy.remoteFallbackTimeout`).
    public static let remoteProbeTimeout: TimeInterval = 4

    public var interfaceClass: SourceRouteInterfaceClass
    /// A tunnel interface is present even if Wi-Fi is still the primary one.
    /// Split tunnels look like `directLocal` while an overlay peer behind them
    /// is as slow to answer as any tunnel.
    public var usesTunnel: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool
    /// Default-path snapshot fields, retained in equality/observation changes.
    /// They do not establish reachability of an endpoint on another interface.
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
    /// plain Wi-Fi, which is exactly what a split tunnel reports. A public
    /// address is not on the LAN either, whatever interface the device is on,
    /// so it must not be judged by the LAN budget.
    public func probeTimeout(for endpoint: SourceConnectionEndpoint?) -> TimeInterval {
        guard let host = endpoint?.normalized.host, host.isEmpty == false else {
            return baseProbeTimeout
        }
        if PrivateOverlayHostPolicy.isOverlayHost(host) {
            return max(baseProbeTimeout, Self.tunnelProbeTimeout)
        }
        if InsecureHTTPHostPolicy.isLocalNetworkHost(host) {
            return baseProbeTimeout
        }
        return max(baseProbeTimeout, Self.remoteProbeTimeout)
    }

    /// A tunnel that just came up drops the packet that triggers its own
    /// handshake. One retry turns that into a working route instead of a
    /// 30-second quarantine; paths without a tunnel keep their single attempt.
    public func retriesTimedOutProbe(for endpoint: SourceConnectionEndpoint?) -> Bool {
        if usesTunnel || interfaceClass == .tunnel { return true }
        guard let host = endpoint?.normalized.host else { return false }
        return PrivateOverlayHostPolicy.isOverlayHost(host)
    }

}

/// What must change about the network path before remembered route verdicts
/// are thrown away.
///
/// `NWPathMonitor` calls back far more often than the path really changes —
/// a DNS or proxy refresh, a radio waking up, the same interfaces reported
/// again. Treating every callback as a new network cleared the private-route
/// cooldowns every few seconds, so a LAN address that could not answer was
/// handshaked again and again. The app monitor and the kit observer both use
/// this value, so they agree on when the path changed.
public struct SourceNetworkPathFingerprint: Hashable, Sendable {
    public enum Transition: Sendable, Equatable {
        /// The first path seen by this observer.
        case initial
        case unchanged
        case changed
    }

    public var status: String
    /// `type:name` for every available interface, sorted.
    public var interfaces: [String]
    /// Gateway endpoints, sorted. Two WLANs on the same interface differ here.
    public var gateways: [String]
    public var supportsIPv4: Bool
    public var supportsIPv6: Bool
    public var isExpensive: Bool
    public var isConstrained: Bool

    public init(
        status: String,
        interfaces: [String],
        gateways: [String],
        supportsIPv4: Bool,
        supportsIPv6: Bool,
        isExpensive: Bool,
        isConstrained: Bool
    ) {
        self.status = status
        self.interfaces = interfaces.sorted()
        self.gateways = gateways.sorted()
        self.supportsIPv4 = supportsIPv4
        self.supportsIPv6 = supportsIPv6
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
    }

    public static func transition(
        from previous: SourceNetworkPathFingerprint?,
        to next: SourceNetworkPathFingerprint
    ) -> Transition {
        guard let previous else { return .initial }
        return previous == next ? .unchanged : .changed
    }

    /// Log-safe description: interface kinds and flags, never addresses.
    public func diagnosticSummary(condition: SourceRoutePathCondition) -> String {
        let kinds = interfaces.map { $0.split(separator: ":", maxSplits: 1).first.map(String.init) ?? $0 }
        let hasCellular = kinds.contains("cellular")
        return "status=\(status) class=\(condition.interfaceClass.rawValue) "
            + "interfaces=\(kinds.isEmpty ? "none" : kinds.joined(separator: ",")) "
            + "tunnel=\(condition.usesTunnel) cellular=\(hasCellular) "
            + "cellularOnly=\(condition.underlyingCellularOnly) gateways=\(gateways.count) "
            + "ipv4=\(supportsIPv4) ipv6=\(supportsIPv6) "
            + "expensive=\(isExpensive) constrained=\(isConstrained)"
    }
}

/// How long a private route that answered TCP but could not finish its
/// protocol handshake is skipped in favour of a configured alternative.
///
/// A VPN or proxy in TUN mode completes the TCP handshake for any private
/// address on the device itself, so "port open" says nothing about the NAS.
/// Retrying such a route on every request cost a full handshake budget each
/// time; the cooldown grows with every consecutive failure and resets as soon
/// as the private route completes a handshake or the network path changes.
public enum SourceLocalHandshakeBackoff {
    public static let schedule: [TimeInterval] = [30, 60, 120, 300]

    /// `consecutiveFailures` counts the failure being recorded, starting at 1.
    public static func interval(afterConsecutiveFailures consecutiveFailures: Int) -> TimeInterval {
        let index = min(max(consecutiveFailures, 1), schedule.count) - 1
        return schedule[index]
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

public extension SourceNetworkPathFingerprint {
    init(path: NWPath) {
        let status: String
        switch path.status {
        case .satisfied: status = "satisfied"
        case .unsatisfied: status = "unsatisfied"
        case .requiresConnection: status = "requiresConnection"
        @unknown default: status = "unknown"
        }
        self.init(
            status: status,
            interfaces: path.availableInterfaces.map { "\(Self.typeName($0.type)):\($0.name)" },
            gateways: path.gateways.map { "\($0)" },
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private static func typeName(_ type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "cellular"
        case .wiredEthernet: return "wired"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }
}
