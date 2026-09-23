import Foundation
import Network
import PrimuseKit

/// Tiny wrapper around `NWPathMonitor` so other services can ask "am I on
/// Wi-Fi right now?" without each spinning up its own monitor.
///
/// Used to gate background metadata backfill on cellular: a 2200-song cloud
/// library would burn through ~550MB of mobile data otherwise.
@MainActor
@Observable
final class NetworkMonitor {
    static let shared = NetworkMonitor()

    private(set) var isExpensive: Bool = false   // cellular / personal hotspot
    private(set) var isConstrained: Bool = false // Low Data Mode
    private(set) var isReachable: Bool = false
    private(set) var hasDeterminedPath: Bool = false
    private(set) var pathGeneration: UInt64 = 0
    /// The full classification of the active path, shared with the source
    /// router so both agree on what a tunnel means.
    private(set) var routePathCondition: SourceRoutePathCondition = .unknown

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.welape.primuse.network-monitor")
    private var pathFingerprint: SourceNetworkPathFingerprint?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let condition = SourceRoutePathCondition(path: path)
            let fingerprint = SourceNetworkPathFingerprint(path: path)
            Task { @MainActor [weak self] in
                self?.apply(
                    reachable: reachable,
                    expensive: expensive,
                    constrained: constrained,
                    condition: condition,
                    fingerprint: fingerprint
                )
            }
        }
        monitor.start(queue: queue)
    }

    private func apply(
        reachable: Bool,
        expensive: Bool,
        constrained: Bool,
        condition: SourceRoutePathCondition,
        fingerprint: SourceNetworkPathFingerprint
    ) {
        // Assign only real changes: every observed write re-evaluates the
        // views and services that read these values.
        if !hasDeterminedPath { hasDeterminedPath = true }
        if isReachable != reachable { isReachable = reachable }
        if isExpensive != expensive { isExpensive = expensive }
        if isConstrained != constrained { isConstrained = constrained }
        if routePathCondition != condition { routePathCondition = condition }
        // The same comparison the source router's observer uses, so both
        // agree on when the network changed. Interfaces and gateways tell two
        // Wi-Fi networks apart; a repeated callback for the same path does
        // not throw away route verdicts, artwork retries or radio probes.
        let transition = SourceNetworkPathFingerprint.transition(from: pathFingerprint, to: fingerprint)
        pathFingerprint = fingerprint
        guard transition != .unchanged else { return }
        pathGeneration &+= 1
        plog("🌐 Network path \(transition == .initial ? "initial" : "changed") generation=\(pathGeneration) \(fingerprint.diagnosticSummary(condition: condition))")
    }

    /// True only when on Wi-Fi (or wired) — false on cellular, hotspot, or
    /// no network. Use as a precondition for kicking off heavy background
    /// transfers when the user has the "Wi-Fi only" toggle on.
    ///
    /// A VPN reports its own `utun` interface, and iOS does not reliably mark
    /// that tunnel as expensive even when it runs over cellular, so the
    /// underlying interfaces are consulted too.
    var isOnUnmeteredNetwork: Bool {
        isReachable
            && !isExpensive
            && !isConstrained
            && !routePathCondition.underlyingCellularOnly
    }

    /// LAN addresses are worth probing whenever the active route could plausibly
    /// reach them. Wi-Fi and Ethernet obviously qualify; so does a tunnel, since
    /// Tailscale/WireGuard/VPN paths appear as `NWInterface` type `.other` and
    /// may carry either the user's overlay network or a split-tunnelled LAN.
    /// Only a plain cellular path starts with the configured public route. The
    /// monitor begins asynchronously, so preserve the existing LAN-first
    /// behavior until its first path arrives instead of briefly preferring WAN
    /// during app launch.
    var prefersLocalConnections: Bool {
        guard hasDeterminedPath else { return true }
        return routePathCondition.prefersPrivateRouteFirst
    }
}
