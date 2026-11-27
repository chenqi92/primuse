import Foundation

/// Bounds automatic catalog preparation and registration while imports keep
/// changing titles and artwork. Direct Siri queries are not scheduled here.
public struct SiriCatalogRefreshSchedule: Sendable {
    public static let debounce: TimeInterval = 0.4
    public static let minimumInterval: TimeInterval = 30

    private var lastStartedAt: TimeInterval?
    private var pendingDeadline: TimeInterval?
    private var pendingForce = false
    private var pendingAllowsRetry = false
    private var running: (force: Bool, allowsRetry: Bool)?

    public init() {}

    /// A nil delay means preparation is running; completion schedules its tail.
    public mutating func request(at now: TimeInterval, force: Bool = false) -> TimeInterval? {
        let deadline = force ? now : max(
            now + Self.debounce,
            lastStartedAt.map { $0 + Self.minimumInterval } ?? now
        )
        // Keep the first pending deadline: continuous artwork notifications
        // must not postpone the last catalog update indefinitely.
        pendingDeadline = min(pendingDeadline ?? deadline, deadline)
        pendingForce = pendingForce || force
        pendingAllowsRetry = true
        return running == nil ? pendingDelay(at: now) : nil
    }

    /// Consumes only the waiting request. New events belong to a later run.
    public mutating func begin(at now: TimeInterval) -> Bool? {
        guard running == nil, pendingDeadline != nil else { return nil }
        let force = pendingForce
        running = (force, pendingAllowsRetry)
        pendingDeadline = nil
        pendingForce = false
        pendingAllowsRetry = false
        lastStartedAt = now
        return force
    }

    public mutating func complete(at now: TimeInterval, succeeded: Bool) -> TimeInterval? {
        guard let completed = running else { return nil }
        running = nil
        if !succeeded {
            pendingForce = pendingForce || completed.force
            if pendingDeadline == nil, completed.allowsRetry {
                // One retry handles a startup race without creating an idle
                // retry loop when the library cannot become ready.
                pendingDeadline = max(now + Self.debounce, (lastStartedAt ?? now) + Self.minimumInterval)
                pendingAllowsRetry = false
            }
        }
        return pendingDelay(at: now)
    }

    private func pendingDelay(at now: TimeInterval) -> TimeInterval? {
        pendingDeadline.map { max(0, $0 - now) }
    }
}
