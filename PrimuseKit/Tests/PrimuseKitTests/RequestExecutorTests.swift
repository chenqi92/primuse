import Foundation
import Testing
@testable import PrimuseKit

@Suite("External HTTP requests")
struct RequestExecutorTests {
    @Test("An overloaded service bounds pending work")
    func boundsPendingRequests() async throws {
        let executor = RequestExecutor(policy: .init(
            maximumConcurrentRequests: 1, maximumPendingRequests: 0, timeout: 0.1
        ))
        let gate = HeldResponse()
        let first = Task { try await executor.execute { try await gate.read() } }
        defer { first.cancel() }
        try await gate.waitUntilStarted()
        do {
            _ = try await executor.execute { reply(200) }
            Issue.record("Expected admission to reject an overloaded service")
        } catch RequestExecutor.AdmissionError.queueFull {
            // Rejected before entering the transport.
        } catch { Issue.record("Expected queueFull, got \(error)") }
    }

    @Test("Cancellation removes a waiting caller without consuming a later slot")
    func cancelsQueuedRequest() async throws {
        let clock = ControlledClock()
        let executor = RequestExecutor(policy: .init(maximumConcurrentRequests: 1), timing: clock.timing)
        let gate = HeldResponse()
        let first = Task { try await executor.execute { try await gate.read() } }
        defer { first.cancel() }
        try await gate.waitUntilStarted()
        let second = Task {
            try await executor.execute { Issue.record("Cancelled work reached transport"); return reply(200) }
        }
        try await clock.waitForSleep(at: 30, count: 2)
        second.cancel()
        do { _ = try await second.value; Issue.record("Expected cancellation") }
        catch { #expect(error is CancellationError) }
        await gate.finish(reply(200))
        _ = try await first.value
        _ = try await executor.execute { reply(200) }
    }

    @Test("Late success and shorter server limits cannot clear a longer cooldown")
    func retainsLongestCooldown() async throws {
        let clock = ControlledClock()
        let executor = RequestExecutor(timing: clock.timing)
        let gates = [HeldResponse(), HeldResponse(), HeldResponse()]
        let tasks = gates.map { gate in Task { try await executor.execute { try await gate.read() } } }
        defer { for task in tasks { task.cancel() } }
        for gate in gates { try await gate.waitUntilStarted() }
        await gates[0].finish(reply(429, headers: ["Retry-After": "3600"]))
        _ = await tasks[0].result
        clock.advance(to: 1)
        await gates[1].finish(reply(503, headers: ["Retry-After": "2"]))
        _ = await tasks[1].result
        await gates[2].finish(reply(200))
        _ = try await tasks[2].value
        do {
            _ = try await executor.execute { Issue.record("Cooldown was cleared"); return reply(200) }
            Issue.record("Expected shared cooldown")
        } catch let failure as HTTPResponseFailure { #expect(failure.retryAfter == 3599) }
        clock.advance(to: 3600)
        _ = try await executor.execute { reply(200) }
    }

    @Test("Writes default to a single attempt after an uncertain outcome")
    func neverReplaysByDefault() async throws {
        let server = FailingServer()
        do {
            _ = try await RequestExecutor().execute { await server.reply() }
            Issue.record("Expected the HTTP failure")
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == 500) }
        #expect(await server.requests == 1)
    }

    @Test("Permanent HTTP and cancellation errors are not retried", arguments: [401, 403, 404])
    func permanentFailures(status: Int) async throws {
        let clock = ControlledClock()
        do {
            _ = try await RequestExecutor(timing: clock.timing).execute(replay: .idempotent) {
                clock.recordStart(); return reply(status)
            }
            Issue.record("Expected permanent HTTP error")
        } catch let failure as HTTPResponseFailure { #expect(failure.statusCode == status) }
        #expect(clock.starts.count == 1)
    }

    @Test("Transport cancellation and uncertain writes are never replayed", arguments: [URLError.Code.cancelled, .networkConnectionLost])
    func transportFailure(code: URLError.Code) async throws {
        let clock = ControlledClock()
        do {
            _ = try await RequestExecutor(timing: clock.timing).execute {
                clock.recordStart(); throw URLError(code)
            }
            Issue.record("Expected transport failure")
        } catch let error as URLError { #expect(error.code == code) }
        #expect(clock.starts.count == 1)
    }

    @Test("The deadline includes waiting for a rate slot")
    func deadlineIncludesRateWait() async throws {
        let executor = RequestExecutor(policy: .init(minimumInterval: 1, timeout: 0.02))
        _ = try await executor.execute { reply(200) }
        do {
            _ = try await executor.execute { Issue.record("Rate wait escaped the deadline"); return reply(200) }
            Issue.record("Expected admission timeout")
        } catch let error as URLError { #expect(error.code == .timedOut) }
    }

    @Test("Malformed Retry-After does not become a duration", arguments: ["", "-1", "1.5", "NaN", "tomorrow"])
    func malformedRetryAfter(value: String) {
        let response = reply(429, headers: ["Retry-After": value]).1 as! HTTPURLResponse
        #expect(HTTPResponseFailure.retryDelay(from: response) == nil)
    }

    @Test("The total deadline cancels an in-flight transport")
    func cancelsAtDeadline() async throws {
        let executor = RequestExecutor(policy: .init(timeout: 0.02))
        let server = CancellationServer()
        do {
            _ = try await executor.execute { try await server.reply() }
            Issue.record("Expected the request deadline")
        } catch let error as URLError {
            #expect(error.code == .timedOut)
        }
        #expect(await server.cancelled)
    }

    @Test("Safe reads have a finite attempt budget")
    func boundsRetries() async throws {
        let clock = ControlledClock()
        let executor = RequestExecutor(timing: clock.timing, jitter: { _ in 0 })
        let server = FailingServer()
        let task = Task {
            do {
                _ = try await executor.execute(replay: .idempotent) { await server.reply() }
                Issue.record("Expected the final HTTP failure")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == 500)
            }
        }
        defer { task.cancel() }
        try await clock.waitForSleep(at: 0.5)
        clock.advance(to: 0.5)
        try await clock.waitForSleep(at: 1.5)
        clock.advance(to: 1.5)
        try await task.value
        #expect(await server.requests == 3)
    }

    @Test("All callers share the in-flight request limit")
    func boundsConcurrency() async throws {
        let executor = RequestExecutor(policy: .init(maximumConcurrentRequests: 2))
        let server = ConcurrentServer()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<20 {
                group.addTask { _ = try await executor.execute { try await server.reply() } }
            }
            try await group.waitForAll()
        }
        #expect(await server.peak == 2)
        #expect(await server.completed == 20)
    }

    @Test("Request starts obey the service interval")
    func spacesRequests() async throws {
        let clock = ControlledClock()
        let executor = RequestExecutor(policy: .init(minimumInterval: 3), timing: clock.timing)
        let task = Task {
            for _ in 0..<3 {
                _ = try await executor.execute { clock.recordStart(); return reply(200) }
            }
        }
        defer { task.cancel() }
        try await clock.waitForSleep(at: 3)
        clock.advance(to: 3)
        try await clock.waitForSleep(at: 6)
        clock.advance(to: 6)
        try await task.value
        #expect(clock.starts == [0, 3, 6])
    }

    @Test("Another caller cannot send during an existing server cooldown", arguments: [429, 503, 500, 403])
    func sharesCooldownAcrossCallers(status: Int) async throws {
        let executor = RequestExecutor()
        let server = RateLimitedServer(status: status)
        for _ in 0..<2 {
            do {
                _ = try await executor.execute { await server.reply() }
                Issue.record("The service is still rate limited")
            } catch let failure as HTTPResponseFailure {
                #expect(failure.statusCode == status)
                #expect(try #require(failure.retryAfter) > 3590)
            }
        }
        #expect(await server.requests == 1)
    }

    @Test("HTTP-date cooldowns use the supplied receipt time", arguments: [
        "Sun, 06 Nov 1994 08:51:37 GMT",
        "Sunday, 06-Nov-94 08:51:37 GMT",
        "Sun Nov  6 08:51:37 1994"
    ])
    func preservesHTTPDate(header: String) throws {
        let now = try #require(ISO8601DateFormatter().date(from: "1994-11-06T08:49:37Z"))
        let response = try #require(HTTPURLResponse(
            url: URL(string: "https://fixture.invalid/read")!, statusCode: 503,
            httpVersion: nil, headerFields: ["Retry-After": header]
        ))
        #expect(HTTPResponseFailure.retryDelay(from: response, now: now) == 120)
    }

    @Test("A server's hour-long cooldown is not shortened")
    func preservesLongRetryAfter() async throws {
        let executor = RequestExecutor()
        let response = HTTPURLResponse(
            url: URL(string: "https://fixture.invalid/read")!, statusCode: 429,
            httpVersion: nil, headerFields: ["Retry-After": "3600"]
        )!
        do {
            _ = try await executor.execute(replay: .idempotent) { (Data(), response) }
            Issue.record("Expected the server's rate limit")
        } catch let failure as HTTPResponseFailure {
            #expect(failure.statusCode == 429)
            #expect(failure.retryAfter == 3600)
        }
    }
}

private actor RateLimitedServer {
    let status: Int
    init(status: Int) { self.status = status }
    var requests = 0

    func reply() -> (Data, URLResponse) {
        requests += 1
        return (Data(), HTTPURLResponse(
            url: URL(string: "https://fixture.invalid/read")!, statusCode: status,
            httpVersion: nil, headerFields: ["Retry-After": "3600"]
        )!)
    }
}

private func reply(_ status: Int, headers: [String: String] = [:]) -> (Data, URLResponse) {
    (Data(), HTTPURLResponse(url: URL(string: "https://fixture.invalid/read")!,
                            statusCode: status, httpVersion: nil, headerFields: headers)!)
}

/// Only the test advances time; rate waits, retry waits and deadline timers
/// observe the same monotonic clock without racing automatic time advances.
private final class ControlledClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant: TimeInterval = 0
    private var recorded: [TimeInterval] = []
    private var sleepers: [UUID: (TimeInterval, CheckedContinuation<Void, Error>)] = [:]
    var now: TimeInterval { lock.withLock { instant } }
    var starts: [TimeInterval] { lock.withLock { recorded } }
    func recordStart() { lock.withLock { recorded.append(instant) } }
    func advance(to value: TimeInterval) {
        let ready = lock.withLock {
            instant = value
            let ready = sleepers.filter { $0.value.0 <= value }
            for id in ready.keys { sleepers.removeValue(forKey: id) }
            return Array(ready.values)
        }
        for (_, continuation) in ready { continuation.resume() }
    }
    private func sleep(_ interval: TimeInterval) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.withLock {
                    if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                    else { sleepers[id] = (instant + interval, continuation) }
                }
            }
        } onCancel: {
            self.lock.withLock { self.sleepers.removeValue(forKey: id) }?.1.resume(throwing: CancellationError())
        }
    }
    func waitForSleep(at deadline: TimeInterval, count: Int = 1) async throws {
        for _ in 0..<2000 {
            if lock.withLock({ sleepers.values.filter { abs($0.0 - deadline) < 0.00001 }.count >= count }) { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    var timing: RequestExecutor.Timing {
        .init(now: { self.now }, sleep: { try await self.sleep($0) })
    }
}

private actor ConcurrentServer {
    var active = 0
    var peak = 0
    var completed = 0
    func reply() async throws -> (Data, URLResponse) {
        active += 1
        peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(for: .milliseconds(10))
        completed += 1
        return (Data(), HTTPURLResponse(url: URL(string: "https://fixture.invalid/read")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor FailingServer {
    var requests = 0
    func reply() -> (Data, URLResponse) {
        requests += 1
        return (Data(), HTTPURLResponse(url: URL(string: "https://fixture.invalid/read")!,
                                       statusCode: 500, httpVersion: nil, headerFields: nil)!)
    }
}

private actor CancellationServer {
    var cancelled = false
    func reply() async throws -> (Data, URLResponse) {
        do { try await Task.sleep(for: .milliseconds(200)) }
        catch { cancelled = true; throw error }
        return (Data(), HTTPURLResponse(url: URL(string: "https://fixture.invalid/read")!,
                                       statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

private actor HeldResponse {
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var started = false
    func read() async throws -> (Data, URLResponse) {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                started = true
            }
        } onCancel: { Task { await self.cancel() } }
    }
    func waitUntilStarted() async throws {
        for _ in 0..<2000 {
            if started { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw URLError(.timedOut)
    }
    func finish(_ response: (Data, URLResponse)) {
        continuation?.resume(returning: response)
        continuation = nil
    }
    private func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
