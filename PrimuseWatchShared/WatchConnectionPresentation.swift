import Foundation

struct WatchConnectionPresentation {
    static let recoveryInterval: TimeInterval = 3
    private(set) var isActive = false
    private(set) var isReachable = false
    private(set) var unreachableSince: Date?

    mutating func setActive(_ active: Bool, reachable: Bool, now: Date) {
        let resumed = active && !isActive
        isActive = active
        if !active || resumed { unreachableSince = nil }
        update(reachable: reachable, now: now)
    }

    mutating func update(reachable: Bool, now: Date) {
        isReachable = reachable
        if reachable || !isActive {
            unreachableSince = nil
        } else if unreachableSince == nil {
            unreachableSince = now
        }
    }

    func showsDisconnected(at now: Date) -> Bool {
        guard isActive, !isReachable, let unreachableSince else { return false }
        return now.timeIntervalSince(unreachableSince) >= Self.recoveryInterval
    }
}
