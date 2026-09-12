import Foundation

/// Exponential backoff for restarting a network listener that failed to bind.
///
/// A listener bound to a fixed port can fail persistently (the port is held by
/// another process, the interface is gone, the sandbox denies the bind). An
/// immediate restart in the failure handler turns that into a hot loop, so the
/// delay grows with every consecutive attempt and eventually gives up.
///
/// Jitter is supplied by the caller as a unit value so the schedule stays
/// deterministic for tests while production can pass a random unit.
public struct ListenerRestartBackoff: Sendable {
    /// Delay used for the first retry.
    public var baseDelay: TimeInterval
    /// Growth factor applied per consecutive failure.
    public var multiplier: Double
    /// Upper bound for the computed delay, before jitter.
    public var maximumDelay: TimeInterval
    /// Number of retries allowed before the caller must degrade.
    public var maximumAttempts: Int
    /// Relative spread applied around the computed delay (0.2 == +/-20%).
    public var jitterFraction: Double

    public init(
        baseDelay: TimeInterval = 0.5,
        multiplier: Double = 2,
        maximumDelay: TimeInterval = 30,
        maximumAttempts: Int = 8,
        jitterFraction: Double = 0.2
    ) {
        self.baseDelay = baseDelay
        self.multiplier = multiplier
        self.maximumDelay = maximumDelay
        self.maximumAttempts = maximumAttempts
        self.jitterFraction = jitterFraction
    }

    /// Delay before the retry that follows `attempt` previous consecutive
    /// failures (0-based), or `nil` once the retry budget is exhausted.
    ///
    /// - Parameter jitterUnit: Caller supplied randomness in `0...1`; values
    ///   outside that range are clamped. `0.5` yields the unjittered delay.
    public func delay(forAttempt attempt: Int, jitterUnit: Double) -> TimeInterval? {
        guard attempt >= 0, attempt < maximumAttempts else { return nil }
        // Stepwise clamping instead of pow() keeps long schedules finite and
        // avoids an intermediate overflow before the cap is applied.
        var delay = baseDelay
        for _ in 0..<attempt {
            delay = min(maximumDelay, delay * multiplier)
        }
        delay = min(maximumDelay, delay)
        let unit = min(max(jitterUnit, 0), 1)
        let scale = 1 + jitterFraction * (2 * unit - 1)
        return max(0, delay * scale)
    }
}

/// Generation-aware, single-flight restart state machine for a network
/// listener.
///
/// Every listener instance is tagged with the generation that created it. Late
/// callbacks from a cancelled listener carry an old generation and are
/// rejected, so a restart can never be driven twice for the same failure and a
/// dead listener can never cancel a live one. Only one retry may be in flight:
/// further failures while waiting (or after degrading) are ignored.
public struct ListenerRestartStateMachine: Sendable {
    public enum State: Sendable, Equatable {
        /// Not started, or torn down.
        case idle
        /// A listener of the current generation is installed.
        case listening
        /// A retry is scheduled; no listener is installed.
        case waitingRetry
        /// The retry budget is exhausted; the caller must surface an error.
        case degraded
    }

    /// What the caller must do in response to an input.
    public enum Action: Equatable, Sendable {
        /// Build and start a listener tagged with this generation.
        case startListener(generation: UInt64)
        /// Wait `after` seconds, then feed `retryDue(generation:)` back in.
        case scheduleRetry(after: TimeInterval, generation: UInt64)
        /// Give up after this many retries and enter a stable error state.
        case enterDegraded(afterAttempts: Int)
        /// Stale or duplicate input; change nothing.
        case ignore
    }

    private var generation: UInt64 = 0
    private var attempt: Int = 0
    private var state: State = .idle
    private let backoff: ListenerRestartBackoff

    public init(backoff: ListenerRestartBackoff = ListenerRestartBackoff()) {
        self.backoff = backoff
    }

    /// Generation the live listener must carry for its callbacks to count.
    public var currentGeneration: UInt64 { generation }
    /// Consecutive failures that have already been retried.
    public var currentAttempt: Int { attempt }
    public var isDegraded: Bool { state == .degraded }
    public var isWaitingRetry: Bool { state == .waitingRetry }
    public var currentState: State { state }

    /// Begin a fresh listening session; any older callback becomes stale.
    public mutating func start() -> Action {
        generation &+= 1
        attempt = 0
        state = .listening
        return .startListener(generation: generation)
    }

    /// The listener of `generation` reported ready; the failure streak ends.
    public mutating func listenerReady(generation: UInt64) -> Action {
        guard generation == self.generation else { return .ignore }
        attempt = 0
        state = .listening
        return .ignore
    }

    /// The listener of `generation` failed. Single flight: only a failure from
    /// the live listener while it is actually listening starts a retry.
    public mutating func listenerFailed(generation: UInt64, jitterUnit: Double) -> Action {
        guard generation == self.generation, state == .listening else { return .ignore }
        guard let delay = backoff.delay(forAttempt: attempt, jitterUnit: jitterUnit) else {
            // Budget exhausted: report the retries actually spent.
            state = .degraded
            return .enterDegraded(afterAttempts: attempt)
        }
        attempt += 1
        state = .waitingRetry
        return .scheduleRetry(after: delay, generation: generation)
    }

    /// The scheduled retry for `generation` came due.
    public mutating func retryDue(generation: UInt64) -> Action {
        guard generation == self.generation, state == .waitingRetry else { return .ignore }
        self.generation &+= 1
        state = .listening
        return .startListener(generation: self.generation)
    }

    /// Tear down; bumping the generation invalidates in-flight callbacks.
    public mutating func stop() {
        generation &+= 1
        attempt = 0
        state = .idle
    }
}
