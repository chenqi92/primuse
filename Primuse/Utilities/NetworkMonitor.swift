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
    /// 路径确定不通（`.unsatisfied`）。`.requiresConnection` 不算：按需连接的 VPN
    /// 要先有请求才会拨起来。
    private(set) var isUnsatisfied: Bool = false
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
            let unsatisfied = path.status == .unsatisfied
            let unsatisfiedReason = unsatisfied ? Self.describe(path.unsatisfiedReason) : nil
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            let condition = SourceRoutePathCondition(path: path)
            let fingerprint = SourceNetworkPathFingerprint(path: path)
            Task { @MainActor [weak self] in
                self?.apply(
                    reachable: reachable,
                    unsatisfied: unsatisfied,
                    unsatisfiedReason: unsatisfiedReason,
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
        unsatisfied: Bool,
        unsatisfiedReason: String?,
        expensive: Bool,
        constrained: Bool,
        condition: SourceRoutePathCondition,
        fingerprint: SourceNetworkPathFingerprint
    ) {
        // Assign only real changes: every observed write re-evaluates the
        // views and services that read these values.
        if !hasDeterminedPath { hasDeterminedPath = true }
        if isReachable != reachable { isReachable = reachable }
        if isUnsatisfied != unsatisfied { isUnsatisfied = unsatisfied }
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
        let reason = unsatisfiedReason.map { " unsatisfiedReason=\($0)" } ?? ""
        plog("🌐 Network path \(transition == .initial ? "initial" : "changed") generation=\(pathGeneration) \(fingerprint.diagnosticSummary(condition: condition))\(reason)")
    }

    /// `wifiDenied` / `cellularDenied` 是用户在系统设置里不让这个 App 联网（国行机型的
    /// 「无线数据」）；日志里要分得出这种和真的没网。
    private nonisolated static func describe(_ reason: NWPath.UnsatisfiedReason) -> String {
        switch reason {
        case .notAvailable: "notAvailable"
        case .cellularDenied: "cellularDenied"
        case .wifiDenied: "wifiDenied"
        case .localNetworkDenied: "localNetworkDenied"
        default: "other"
        }
    }

    /// 不是用户点出来的联网请求（导入后补资料、开播自动找歌词、自动检查更新）发之前先问这里。
    /// 路径确定不通就不发：用户不让这个 App 联网时，每发一次系统就弹一次「已关闭无线数据」，
    /// 真没网时发了也只会失败再重试。第一次路径回调之前照旧放行，启动时就要发的先
    /// `waitForInitialPath()`。
    var allowsAutomaticInternetRequests: Bool {
        !hasDeterminedPath || !isUnsatisfied
    }

    /// 监视器是异步开始的，刚启动那一下还不知道通不通。启动时就要发自动请求的地方
    /// 先等第一次路径回调，最多等 `timeout`。
    func waitForInitialPath(timeout: Duration = .seconds(2)) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !hasDeterminedPath, !Task.isCancelled, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
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

    /// 连着网、而且这条路计流量（蜂窝、个人热点、低数据模式）。没网、不让这个 App 联网、
    /// 路径还没回来时都是 false：那时什么也发不出去，谈不上费流量，不能拿「当前为蜂窝网络」
    /// 去问用户。
    var isOnMeteredNetwork: Bool {
        hasDeterminedPath && isReachable && !isOnUnmeteredNetwork
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
