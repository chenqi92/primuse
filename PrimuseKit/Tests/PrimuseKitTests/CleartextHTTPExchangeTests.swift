import Foundation
import Network
import Testing
@testable import PrimuseKit

@Suite("Plain-socket HTTP connection gate")
struct HTTPEndpointConnectionGateTests {
    private let endpoint = "http://203.0.113.7:4533"

    @Test("Never runs more exchanges against one endpoint than the limit")
    func respectsTheLimit() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 2)
        let first = try await gate.acquire(endpoint: endpoint)
        let second = try await gate.acquire(endpoint: endpoint)
        let third = Task { try await gate.acquire(endpoint: endpoint) }
        try await waitUntil { gate.occupancy(endpoint: endpoint).queued == 1 }
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 2, queued: 1))

        first.release()
        let permit = try await third.value
        #expect(permit.ahead == 2)
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 2, queued: 0))
        second.release()
        permit.release()
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 0, queued: 0))
    }

    @Test("Queued requests start in the order they arrived")
    func firstInFirstOut() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 1)
        let holder = try await gate.acquire(endpoint: endpoint)
        let order = OrderRecorder()
        var tasks: [Task<Void, any Error>] = []
        for index in 0..<4 {
            tasks.append(Task {
                let permit = try await gate.acquire(endpoint: endpoint)
                order.append(String(index))
                permit.release()
            })
            try await waitUntil { gate.occupancy(endpoint: endpoint).queued == index + 1 }
        }
        holder.release()
        for task in tasks { try await task.value }
        #expect(order.values == ["0", "1", "2", "3"])
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 0, queued: 0))
    }

    @Test("Media range reads wait ahead of other requests, in their own arrival order")
    func mediaLaneGoesFirst() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 1)
        let holder = try await gate.acquire(endpoint: endpoint)
        let order = OrderRecorder()
        let lanes: [(String, HTTPEndpointConnectionGate.Lane)] = [
            ("cover-1", .standard), ("cover-2", .standard), ("range-1", .media), ("cover-3", .standard), ("range-2", .media),
        ]
        var tasks: [Task<Void, any Error>] = []
        for (index, entry) in lanes.enumerated() {
            tasks.append(Task {
                let permit = try await gate.acquire(endpoint: endpoint, lane: entry.1)
                order.append(entry.0)
                permit.release()
            })
            try await waitUntil { gate.occupancy(endpoint: endpoint).queued == index + 1 }
        }
        holder.release()
        for task in tasks { try await task.value }
        #expect(order.values == ["range-1", "range-2", "cover-1", "cover-2", "cover-3"])
    }

    @Test("A request cancelled while queued leaves without taking a slot")
    func cancellationWhileQueued() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 1)
        let holder = try await gate.acquire(endpoint: endpoint)
        let waiting = Task { try await gate.acquire(endpoint: endpoint) }
        let behind = Task { try await gate.acquire(endpoint: endpoint) }
        try await waitUntil { gate.occupancy(endpoint: endpoint).queued == 2 }

        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 1, queued: 1))

        holder.release()
        let next = try await behind.value
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 1, queued: 0))
        next.release()
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 0, queued: 0))
    }

    @Test("An already cancelled task never takes a slot")
    func cancelledBeforeArriving() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await gate.acquire(endpoint: endpoint)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 0, queued: 0))
    }

    @Test("Releasing twice or dropping a permit frees exactly one slot")
    func releaseIsIdempotent() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 2)
        let first = try await gate.acquire(endpoint: endpoint)
        let second = try await gate.acquire(endpoint: endpoint)
        first.release()
        first.release()
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 1, queued: 0))
        try await dropPermit(gate)
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 1, queued: 0))
        second.release()
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 0, queued: 0))
    }

    @Test("Each host:port has its own slots")
    func endpointsAreIndependent() async throws {
        let gate = HTTPEndpointConnectionGate(limit: 1)
        let held = try await gate.acquire(endpoint: endpoint)
        let other = try await gate.acquire(endpoint: "http://203.0.113.7:8080")
        #expect(gate.occupancy(endpoint: endpoint) == .init(running: 1, queued: 0))
        held.release()
        other.release()
    }

    /// Takes a slot and lets the permit go out of scope without releasing it.
    private func dropPermit(_ gate: HTTPEndpointConnectionGate) async throws {
        _ = try await gate.acquire(endpoint: endpoint)
    }
}

@Suite("Retrying an exchange the network cut off")
struct CleartextHTTPRetryPolicyTests {
    @Test("Only a bodyless GET with time left is tried once more", arguments: CleartextHTTPExchangeFailure.allCases)
    func retriesOnlyIdempotentReads(failure: CleartextHTTPExchangeFailure) {
        #expect(CleartextHTTPRetryPolicy.shouldRetry(
            method: "GET", hasBody: false, failure: failure, retriesSoFar: 0, remainingTime: 9
        ))
        #expect(CleartextHTTPRetryPolicy.shouldRetry(
            method: nil, hasBody: false, failure: failure, retriesSoFar: 0, remainingTime: 9
        ))
        #expect(!CleartextHTTPRetryPolicy.shouldRetry(
            method: "GET", hasBody: false, failure: failure, retriesSoFar: 1, remainingTime: 9
        ))
        #expect(!CleartextHTTPRetryPolicy.shouldRetry(
            method: "GET", hasBody: false, failure: failure, retriesSoFar: 0, remainingTime: 1.5
        ))
        for method in ["POST", "PUT", "DELETE", "PATCH", "HEAD"] {
            #expect(!CleartextHTTPRetryPolicy.shouldRetry(
                method: method, hasBody: false, failure: failure, retriesSoFar: 0, remainingTime: 9
            ))
        }
        #expect(!CleartextHTTPRetryPolicy.shouldRetry(
            method: "GET", hasBody: true, failure: failure, retriesSoFar: 0, remainingTime: 9
        ))
    }

    @Test("The pause before the second attempt stays short")
    func backoffIsBounded() {
        #expect(CleartextHTTPRetryPolicy.backoff(randomFraction: 0) == 0.4)
        #expect(abs(CleartextHTTPRetryPolicy.backoff(randomFraction: 1) - 0.7) < 0.000_1)
        #expect(CleartextHTTPRetryPolicy.backoff(randomFraction: -3) == 0.4)
        #expect(abs(CleartextHTTPRetryPolicy.backoff(randomFraction: 8) - 0.7) < 0.000_1)
    }

    @Test("A reset after the connection came up counts as cut off; other failures do not")
    func peerResetClassification() {
        #expect(CleartextHTTPExchangeFailure.isPeerReset(NWError.posix(.ECONNRESET)))
        #expect(CleartextHTTPExchangeFailure.isPeerReset(NWError.posix(.EPIPE)))
        #expect(CleartextHTTPExchangeFailure.isPeerReset(NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNABORTED))))
        #expect(!CleartextHTTPExchangeFailure.isPeerReset(NWError.posix(.ECONNREFUSED)))
        #expect(!CleartextHTTPExchangeFailure.isPeerReset(NWError.posix(.ETIMEDOUT)))
        #expect(!CleartextHTTPExchangeFailure.isPeerReset(URLError(.timedOut)))
        #expect(!CleartextHTTPExchangeFailure.isPeerReset(CancellationError()))
    }

    @Test("Each kind of cut-off reads differently in the diagnostic log")
    func descriptionsAreDistinct() {
        let descriptions = Set(CleartextHTTPExchangeFailure.allCases.map(\.diagnosticDescription))
        #expect(descriptions.count == CleartextHTTPExchangeFailure.allCases.count)
    }
}

@Suite("How long a failed source cover is left alone")
struct SourceArtworkFailureRetentionTests {
    @Test("A cover the source does not have waits the full window")
    func missingCoverWaitsFiveMinutes() {
        let retention = SourceArtworkFailureRetention()
        #expect(retention.suppressionInterval(sourceID: "nas", reference: "subsonic-cover/1") == 5 * 60)
        #expect(retention.suppressionInterval(sourceID: nil, reference: "subsonic-cover/1") == 5 * 60)
    }

    @Test("A transfer the network cut off is asked again soon, only for that cover")
    func interruptedTransferRetriesSoon() {
        let retention = SourceArtworkFailureRetention()
        let now = Date()
        retention.recordInterruptedTransfer(sourceID: "nas", reference: "subsonic-cover/1", at: now)
        #expect(retention.suppressionInterval(sourceID: "nas", reference: "subsonic-cover/1", now: now) == 30)
        #expect(retention.suppressionInterval(sourceID: "nas", reference: "subsonic-cover/2", now: now) == 5 * 60)
        #expect(retention.suppressionInterval(sourceID: "other", reference: "subsonic-cover/1", now: now) == 5 * 60)
    }

    @Test("A later answer from the source replaces the cut-off")
    func settledLoadClearsTheMark() {
        let retention = SourceArtworkFailureRetention()
        retention.recordInterruptedTransfer(sourceID: "nas", reference: "subsonic-cover/1")
        retention.recordSettledLoad(sourceID: "nas", reference: "subsonic-cover/1")
        #expect(retention.suppressionInterval(sourceID: "nas", reference: "subsonic-cover/1") == 5 * 60)
    }

    @Test("An old cut-off no longer explains a new failure")
    func staleMarkExpires() {
        let retention = SourceArtworkFailureRetention()
        let then = Date()
        retention.recordInterruptedTransfer(sourceID: "nas", reference: "subsonic-cover/1", at: then)
        let later = then.addingTimeInterval(SourceArtworkFailureRetention.observationWindow + 1)
        #expect(retention.suppressionInterval(sourceID: "nas", reference: "subsonic-cover/1", now: later) == 5 * 60)
    }
}

private final class OrderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    func append(_ value: String) {
        lock.withLock { recorded.append(value) }
    }

    var values: [String] { lock.withLock { recorded } }
}

private struct ConditionTimedOut: Error {}

/// Polls instead of sleeping a fixed time, so a loaded machine only makes the test slower.
private func waitUntil(timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { throw ConditionTimedOut() }
        try await Task.sleep(for: .milliseconds(5))
    }
}
