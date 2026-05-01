import Foundation
import Network

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

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.welape.primuse.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let reachable = path.status == .satisfied
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor [weak self] in
                self?.isReachable = reachable
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: queue)
    }

    /// True only when on Wi-Fi (or wired) — false on cellular, hotspot, or
    /// no network. Use as a precondition for kicking off heavy background
    /// transfers when the user has the "Wi-Fi only" toggle on.
    var isOnUnmeteredNetwork: Bool {
        isReachable && !isExpensive && !isConstrained
    }
}
