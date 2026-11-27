import Foundation
import Testing
@testable import PrimuseKit

@Suite struct PlexAccountQuotaTests {
    @Test(arguments: ["3600", "1000000000000000000000000000000"])
    func cooldownBeyondCreatedPINLifetimeFailsWithoutSleeping(header: String) async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(replies: [
            .init(body: #"{"id":1,"code":"short","expiresIn":10}"#),
            .init(status: 429, headers: ["Retry-After": header]),
            .init(body: #"{"id":1,"code":"short","authToken":"too-late"}"#)
        ], clock: clock)
        let client = makeClient(wire, clock: clock)
        let pin = try await client.createPin(strong: false)
        await #expect(throws: HTTPResponseFailure.self) { _ = try await client.waitForToken(pinIDs: [pin.id]) }
        #expect(await wire.requests.count == 2)
        #expect(clock.now == 2, "An expired-before-retry PIN cannot hold the sign-in screen open")
    }

    @Test func pendingResponseExpiryStopsBeforeTheNextPoll() async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(replies: [
            .init(body: #"{"id":1,"code":"short","expiresIn":1}"#),
            .init(body: #"{"id":1,"code":"short","authToken":"too-late"}"#)
        ], clock: clock)
        await #expect(throws: PlexAccountError.pinExpired) {
            _ = try await makeClient(wire, clock: clock).waitForToken(pinIDs: [1])
        }
        #expect(await wire.requests.count == 1)
    }

    @Test func repeatedServiceUnavailableExhaustsFiveFailureBudget() async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(replies: Array(repeating: .init(status: 503), count: 5) + [
            .init(body: #"{"id":1,"code":"short","authToken":"unexpected-sixth-poll"}"#)
        ], clock: clock)
        await #expect(throws: HTTPResponseFailure.self) {
            _ = try await makeClient(wire, clock: clock).waitForToken(pinIDs: [1])
        }
        #expect(await wire.requests.count == 5)
        #expect(clock.now == 122)
    }

    @Test func longCooldownIsSharedAcrossPINsAndAccountResources() async throws {
        let wire = PlexQuotaWire(status: 429, headers: ["Retry-After": "3600"])
        let client = PlexAccountClient(clientIdentifier: UUID().uuidString, platform: "test", deviceName: "fixture", version: "1", loader: { try await wire.send($0) })
        for operation in 0..<3 {
            do {
                if operation == 2 { _ = try await client.servers(accountToken: "fixture-token") }
                else { _ = try await client.checkPin(id: operation) }
                Issue.record("Expected cooldown")
            } catch {
                let failure = error as? HTTPResponseFailure
                #expect(failure?.statusCode == 429)
                #expect((failure?.retryAfter ?? 0) > 3590)
            }
        }
        #expect(await wire.requests.count == 1)
    }

    @Test(arguments: [false, true])
    func pollingHonorsRepeatedCooldownsWithinPINLifetime(multiple: Bool) async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(replies: Array(repeating: .init(status: 429, headers: ["Retry-After": "10"]), count: 6) +
            (multiple ? [.init(body: #"{"id":1,"code":"pending"}"#)] : []) +
            [.init(body: #"{"id":2,"code":"ok","authToken":"authorized"}"#)], clock: clock)
        let client = makeClient(wire, clock: clock)
        let token = try await client.waitForToken(pinIDs: multiple ? [1, 2] : [1])
        #expect(token == "authorized")
        let times = await wire.times
        #expect(times.count == (multiple ? 8 : 7))
        #expect(times.first == 2)
        #expect(times[6] == 62, "Genuine quotas within the PIN lifetime must not exhaust the service-failure budget")
    }

    @Test(arguments: [429, 503])
    func missingHeaderStillPausesPollingForTheSharedDefault(status: Int) async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(replies: [.init(status: status), .init(body: #"{"id":1,"code":"ok","authToken":"token"}"#)], clock: clock)
        let token = try await makeClient(wire, clock: clock).waitForToken(pinIDs: [1])
        #expect(token == "token")
        #expect(await wire.times == [2, 32])
    }

    @Test func dateCooldownIsSharedByNewClientsButNotOtherDeviceIdentities() async throws {
        let clock = PlexPollClock()
        let registry = RequestQuotaRegistry(timing: clock.requestTiming)
        let wire = PlexQuotaWire(status: 503, headers: ["Retry-After": "Mon, 12 Oct 2026 02:00:00 GMT"])
        let first = makeClient(wire, clock: clock, registry: registry, id: "same")
        let second = makeClient(wire, clock: clock, registry: registry, id: "same")
        for client in [first, second] {
            do { _ = try await client.checkPin(id: 1); Issue.record("Expected cooldown") }
            catch let failure as HTTPResponseFailure { #expect(failure.retryAfter == 7200) }
        }
        #expect(await wire.requests.count == 1)
        _ = try? await makeClient(wire, clock: clock, registry: registry, id: "other").checkPin(id: 2)
        #expect(await wire.requests.count == 2)
    }

    @Test func creatingPINNeverReplaysAmbiguousFailure() async throws {
        for reply in [PlexReply(status: 502), PlexReply(status: 429, headers: ["Retry-After": "1"]), PlexReply(error: .init(.timedOut))] {
            let wire = PlexQuotaWire(replies: [reply])
            _ = try? await makeClient(wire).createPin(strong: true)
            let requests = await wire.requests
            #expect(requests.count == 1)
            #expect(requests.first?.httpMethod == "POST")
            #expect(requests.first?.url?.query == "strong=true")
        }
    }

    @Test func readRecoversWithinTwoAttemptBudget() async throws {
        let wire = PlexQuotaWire(replies: [.init(status: 502), .init(body: #"{"id":1,"code":"pending"}"#)])
        let pin = try await makeClient(wire).checkPin(id: 1)
        #expect(pin.authToken == nil)
        #expect(await wire.requests.count == 2)
    }

    @Test func pendingPINStillExpiresAndUnauthorizedIsTerminal() async throws {
        for status in [401, 403, 404] {
            let clock = PlexPollClock()
            let wire = PlexQuotaWire(replies: [.init(body: #"{"id":1,"code":"pending"}"#), .init(status: status)])
            await #expect(throws: status == 404 ? PlexAccountError.pinExpired : .unauthorized) {
                _ = try await makeClient(wire, clock: clock).waitForToken(pinIDs: [1])
            }
            #expect(await wire.requests.count == 2)
        }
    }

    @Test func ordinaryFailuresHaveFinitePollBudget() async throws {
        let wire = PlexQuotaWire(status: 400)
        await #expect(throws: HTTPResponseFailure.self) {
            _ = try await makeClient(wire, clock: PlexPollClock()).waitForToken(pinIDs: [1])
        }
        #expect(await wire.requests.count == 5)
    }

    @Test func closingPageAllowsFinalNormalCheckButNoRequestDuringCooldown() async throws {
        let authorized = PlexQuotaWire(replies: [.init(body: #"{"id":1,"code":"ok","authToken":"token"}"#)])
        let token = try await makeClient(authorized, clock: PlexPollClock()).waitForToken(pinIDs: [1], authorizationPageClosed: { true })
        #expect(token == "token")
        let throttled = PlexQuotaWire(status: 429, headers: ["Retry-After": "3600"])
        let closed = try await makeClient(throttled, clock: PlexPollClock()).waitForToken(pinIDs: [1], authorizationPageClosed: {
            await !throttled.requests.isEmpty
        })
        #expect(closed == nil)
        #expect(await throttled.requests.count == 1)
    }

    @Test func cancellationInterruptsLongCooldown() async throws {
        let clock = PlexPollClock()
        let wire = PlexQuotaWire(status: 429, headers: ["Retry-After": "60"])
        let timing = RequestExecutor.Timing(now: { clock.now }, sleep: { seconds in
            if seconds > 10 {
                clock.markWaiting()
                try await Task.sleep(for: .seconds(seconds))
            } else { clock.advance(seconds) }
        })
        let client = PlexAccountClient(clientIdentifier: UUID().uuidString, platform: "test", deviceName: "fixture", version: "1", loader: { try await wire.send($0) }, quotaRegistry: RequestQuotaRegistry(), pollingTiming: timing)
        let task = Task { try await client.waitForToken(pinIDs: [1, 2]) }
        for _ in 0..<200 {
            if clock.waiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(clock.waiting)
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(await wire.requests.count == 1)
    }

    @Test func cancelledTransportDoesNotPollAgain() async throws {
        let wire = PlexQuotaWire(replies: [.init(error: .init(.cancelled))])
        await #expect(throws: CancellationError.self) {
            _ = try await makeClient(wire, clock: PlexPollClock()).waitForToken(pinIDs: [1, 2])
        }
        #expect(await wire.requests.count == 1)
    }

    private func makeClient(_ wire: PlexQuotaWire, clock: PlexPollClock? = nil,
                            registry: RequestQuotaRegistry? = nil, id: String = UUID().uuidString) -> PlexAccountClient {
        PlexAccountClient(clientIdentifier: id, platform: "test", deviceName: "fixture", version: "1",
                          loader: { try await wire.send($0) },
                          quotaRegistry: registry ?? RequestQuotaRegistry(timing: clock?.requestTiming ?? .init()),
                          pollingTiming: clock?.pollTiming ?? .init())
    }
}

private struct PlexReply: Sendable {
    var status: Int = 200
    var headers: [String: String] = [:]
    var body: String = "{}"
    var error: URLError? = nil
}

private actor PlexQuotaWire {
    let replies: [PlexReply]
    let clock: PlexPollClock?
    private(set) var requests: [URLRequest] = []
    private(set) var times: [TimeInterval] = []
    init(status: Int, headers: [String: String] = [:]) {
        replies = [.init(status: status, headers: headers)]; clock = nil
    }
    init(replies: [PlexReply], clock: PlexPollClock? = nil) { self.replies = replies; self.clock = clock }
    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        let reply = replies[min(requests.count, replies.count - 1)]
        requests.append(request); times.append(clock?.now ?? 0)
        if let error = reply.error { throw error }
        return (Data(reply.body.utf8), HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!)
    }
}

private final class PlexPollClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: TimeInterval = 0
    private var isWaiting = false
    var now: TimeInterval { lock.withLock { time } }
    var waiting: Bool { lock.withLock { isWaiting } }
    func advance(_ seconds: TimeInterval) { lock.withLock { time += seconds } }
    func markWaiting() { lock.withLock { isWaiting = true } }
    var requestTiming: RequestExecutor.Timing {
        .init(now: { self.now }, date: { Date(timeIntervalSince1970: 1_791_763_200 + self.now) })
    }
    var pollTiming: RequestExecutor.Timing {
        .init(now: { self.now }, sleep: { seconds in
            try Task.checkCancellation(); self.advance(seconds); await Task.yield()
        })
    }
}
