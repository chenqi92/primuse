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

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let condition = SourceRoutePathCondition(path: path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.hasDeterminedPath = true
                self.isReachable = reachable
                self.isExpensive = expensive
                self.isConstrained = constrained
                self.routePathCondition = condition
                // The path handler itself is the change signal. Interface-type
                // summaries cannot distinguish two different Wi-Fi networks.
                self.pathGeneration &+= 1
            }
        }
        monitor.start(queue: queue)
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
