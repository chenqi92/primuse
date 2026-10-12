import Foundation

/// An HTTP failure retains the response needed by provider-specific adapters.
public struct HTTPResponseFailure: Error, Sendable, LocalizedError {
    public let statusCode: Int
    public let body: Data
    public let retryAfter: TimeInterval?
    /// Provider adapters may classify a business error without replacing its HTTP status.
    public let isRateLimited: Bool
    public let isRetryable: Bool?

    public init(
        statusCode: Int, body: Data = Data(), retryAfter: TimeInterval? = nil,
        isRateLimited: Bool = false, isRetryable: Bool? = nil
    ) {
        self.statusCode = statusCode
        self.body = body
        self.retryAfter = retryAfter
        self.isRateLimited = isRateLimited
        self.isRetryable = isRetryable
    }

    public var errorDescription: String? { PMString("ext.tv.playback.httpError", statusCode) }

    public static func retryDelay(from response: HTTPURLResponse, now: Date = Date()) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After")?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if value.utf8.allSatisfy({ (48...57).contains($0) }),
           let seconds = TimeInterval(value), seconds.isFinite { return seconds }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        for format in [
            "EEE, dd MMM yyyy HH:mm:ss zzz",
            "EEEE, dd-MMM-yy HH:mm:ss zzz",
            "EEE MMM d HH:mm:ss yyyy"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return max(0, date.timeIntervalSince(now))
            }
        }
        return nil
    }
}

/// One instance owns one service/account quota. Share it across that quota's
/// callers; use separate instances for independent services or accounts.
/// The transport remains injectable so each adapter keeps its authentication,
/// trust, redirect and response-size rules. A send closure must honor cancellation.
/// Long server cooldowns are returned as HTTPResponseFailure with the remaining
/// delay instead of holding a task open or shortening the server's limit.
public actor RequestExecutor {
    private var cooldownUntil: TimeInterval = 0
    private var cooldownFailure = HTTPResponseFailure(statusCode: 429)
    private var nextStart: TimeInterval = 0
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    /// Only opt in when repeating the complete operation is safe, including after
    /// a response is lost. Writes and paid generation default to no replay.
    public enum Replay: Sendable { case never, idempotent }
    public enum AdmissionError: Error, Sendable { case queueFull }

    public struct Policy: Sendable, Equatable {
        public let minimumInterval: TimeInterval
        public let maximumConcurrentRequests: Int
        public let maximumPendingRequests: Int
        public let maximumAttempts: Int
        public let maximumRetryWait: TimeInterval
        public let timeout: TimeInterval
        public let defaultCooldown: TimeInterval
        /// Statuses that start a shared cooldown even without Retry-After.
        /// Some services signal their quota with another status (iTunes: 403).
        public let rateLimitStatusCodes: Set<Int>
        public init(
            minimumInterval: TimeInterval = 0, maximumConcurrentRequests: Int = 4,
            maximumPendingRequests: Int = 128,
            maximumAttempts: Int = 3, maximumRetryWait: TimeInterval = 2,
            timeout: TimeInterval = 30, rateLimitStatusCodes: Set<Int> = [429, 503],
            defaultCooldown: TimeInterval = 30
        ) {
            precondition(minimumInterval >= 0 && minimumInterval.isFinite)
            precondition(maximumConcurrentRequests > 0 && maximumPendingRequests >= 0)
            self.maximumPendingRequests = maximumPendingRequests
            precondition(maximumAttempts > 0 && maximumAttempts <= 10)
            precondition(maximumRetryWait >= 0 && maximumRetryWait.isFinite)
            precondition(timeout > 0 && timeout.isFinite)
            precondition(defaultCooldown >= 0 && defaultCooldown.isFinite)
            self.defaultCooldown = defaultCooldown
            self.timeout = timeout
            self.maximumAttempts = maximumAttempts
            self.maximumRetryWait = maximumRetryWait
            self.minimumInterval = minimumInterval
            self.maximumConcurrentRequests = maximumConcurrentRequests
            self.rateLimitStatusCodes = rateLimitStatusCodes
        }
    }

    public struct Timing: Sendable {
        public var now: @Sendable () -> TimeInterval
        public var date: @Sendable () -> Date
        public var sleep: @Sendable (TimeInterval) async throws -> Void
        public init(
            now: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
            date: @escaping @Sendable () -> Date = { Date() },
            sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
                try await Task.sleep(for: .seconds($0))
            }
        ) {
            self.now = now
            self.date = date
            self.sleep = sleep
        }
    }

    private let policy: Policy
    private let timing: Timing
    private let jitter: @Sendable (TimeInterval) -> TimeInterval
    public init(
        policy: Policy = Policy(), timing: Timing = Timing(),
        jitter: @escaping @Sendable (TimeInterval) -> TimeInterval = { .random(in: 0...$0) }
    ) {
        self.policy = policy
        self.timing = timing
        self.jitter = jitter
    }

    /// Schedulers can skip unavailable sources without duplicating or shortening
    /// this executor's cooldown deadline.
    public var isCoolingDown: Bool { cooldownUntil > timing.now() }

    /// An idle registry entry still owns pacing reservations after a success.
    /// Dropping it before that reservation expires would allow an early request.
    var canDiscardQuotaState: Bool {
        active == 0 && waiters.isEmpty && cooldownUntil <= timing.now() && nextStart <= timing.now()
    }

    public func execute(
        minimumInterval: TimeInterval? = nil,
        replay: Replay = .never,
        timeout: TimeInterval? = nil,
        _ send: @escaping @Sendable () async throws -> (Data, URLResponse)
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        let timing = self.timing
        return try await execute(minimumInterval: minimumInterval, replay: replay, timeout: timeout, operation: {
            let (data, response) = try await send()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            guard (200...299).contains(http.statusCode) else {
                throw HTTPResponseFailure(
                    statusCode: http.statusCode, body: data,
                    retryAfter: HTTPResponseFailure.retryDelay(from: http, now: timing.date())
                )
            }
            return (data, http)
        })
    }

    /// Uses the same scheduler for bounded Range reads, streamed file downloads,
    /// and provider envelopes. The operation owns response validation and throws
    /// HTTPResponseFailure when appropriate. It must clean up unreturned resources
    /// and cooperate with cancellation. Recovery (e.g. one token refresh) consumes
    /// the same attempt/time budget as every other retry, even for a rejected write.
    public func execute<Value: Sendable>(
        minimumInterval: TimeInterval? = nil,
        replay: Replay = .never,
        timeout: TimeInterval? = nil,
        recover: (@Sendable (Error) async throws -> Bool)? = nil,
        operation: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let interval = minimumInterval ?? policy.minimumInterval
        precondition(interval >= 0 && interval.isFinite)
        let timeout = timeout ?? policy.timeout
        precondition(timeout > 0 && timeout.isFinite)
        let deadline = timing.now() + min(timeout, policy.timeout)
        let timing = self.timing
        return try await withThrowingTaskGroup(of: Value.self) { group in
            group.addTask { try await self.run(replay: replay, deadline: deadline, minimumInterval: interval, recover: recover, operation) }
            group.addTask {
                let remaining = deadline - timing.now()
                if remaining > 0 { try await timing.sleep(remaining) }
                try Task.checkCancellation()
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func run<Value: Sendable>(
        replay: Replay, deadline: TimeInterval, minimumInterval: TimeInterval,
        recover: (@Sendable (Error) async throws -> Bool)?,
        _ send: @Sendable () async throws -> Value
    ) async throws -> Value {
        for attempt in 1...policy.maximumAttempts {
            do { return try await perform(deadline: deadline, minimumInterval: minimumInterval, send) }
            catch {
                try Task.checkCancellation()
                guard attempt < policy.maximumAttempts else { throw error }
                if let recover, try await recover(error) { continue }
                guard replay == .idempotent, Self.isTransient(error) else { throw error }
                let backoff = min(0.5 * pow(2, Double(attempt - 1)), 8)
                let serverDelay = (error as? HTTPResponseFailure)?.retryAfter ?? 0
                let delay = max(backoff + max(0, jitter(backoff * 0.25)),
                                serverDelay, cooldownUntil - timing.now())
                guard delay <= policy.maximumRetryWait,
                      timing.now() + delay < deadline else { throw error }
                try await timing.sleep(delay)
            }
        }
        preconditionFailure("An attempt either returns or throws")
    }

    private static func isTransient(_ error: Error) -> Bool {
        if let failure = error as? HTTPResponseFailure {
            return failure.isRetryable ?? (failure.isRateLimited ||
                [408, 429, 500, 502, 503, 504].contains(failure.statusCode))
        }
        guard let error = error as? URLError else { return false }
        return [.timedOut, .networkConnectionLost, .cannotConnectToHost,
                .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
                .resourceUnavailable].contains(error.code)
    }

    private func checkCooldown() throws {
        let remaining = cooldownUntil - timing.now()
        if remaining > 0 {
            throw HTTPResponseFailure(
                statusCode: cooldownFailure.statusCode, body: cooldownFailure.body,
                retryAfter: remaining, isRateLimited: cooldownFailure.isRateLimited,
                isRetryable: cooldownFailure.isRetryable
            )
        }
    }

    private func perform<Value: Sendable>(
        deadline: TimeInterval, minimumInterval: TimeInterval,
        _ send: @Sendable () async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        try checkCooldown()
        try await acquire()
        defer { release() }
        while nextStart > timing.now() {
            try await timing.sleep(nextStart - timing.now())
            try Task.checkCancellation()
        }
        try Task.checkCancellation()
        try checkCooldown()
        guard timing.now() < deadline else { throw URLError(.timedOut) }
        nextStart = timing.now() + minimumInterval
        do {
            let value = try await send()
            try Task.checkCancellation()
            guard timing.now() < deadline else { throw URLError(.timedOut) }
            return value
        } catch let failure as HTTPResponseFailure {
            if failure.retryAfter != nil || failure.isRateLimited ||
                policy.rateLimitStatusCodes.contains(failure.statusCode) {
                let until = timing.now() + (failure.retryAfter ?? policy.defaultCooldown)
                if until > cooldownUntil {
                    cooldownUntil = until
                    cooldownFailure = failure
                }
            }
            throw failure
        }
    }

    private func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if active < policy.maximumConcurrentRequests {
                active += 1
                return
            }
            guard waiters.count < policy.maximumPendingRequests else { throw AdmissionError.queueFull }
            try await withCheckedThrowingContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(throwing: CancellationError())
    }

    private func release() {
        if waiters.isEmpty { active -= 1 }
        else { waiters.removeFirst().1.resume() }
    }
}
