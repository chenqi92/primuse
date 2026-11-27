import Foundation
import Testing
@testable import PrimuseKit

@Suite("Throttled cloud flush gate")
struct CloudFlushGateTests {
    @Test("A flush armed and still armed pushes")
    func armedFlushPasses() {
        let token = UUID()
        #expect(CloudFlushGate.shouldFlush(isCancelled: false, currentToken: token, taskToken: token))
    }

    @Test("A cancelled flush never pushes, even while it still owns the token")
    func cancelledFlushIsRejected() {
        let token = UUID()
        #expect(CloudFlushGate.shouldFlush(isCancelled: true, currentToken: token, taskToken: token) == false)
    }

    @Test("A flush whose service was stopped never pushes")
    func stoppedServiceRejectsFlush() {
        let token = UUID()
        #expect(CloudFlushGate.shouldFlush(isCancelled: false, currentToken: nil, taskToken: token) == false)
    }

    @Test("A flush replaced by a restart never pushes — it must not clear the newer handle")
    func restartedServiceRejectsStaleFlush() {
        let stale = UUID()
        let current = UUID()
        #expect(CloudFlushGate.shouldFlush(isCancelled: false, currentToken: current, taskToken: stale) == false)
        #expect(CloudFlushGate.shouldFlush(isCancelled: true, currentToken: current, taskToken: stale) == false)
    }

    @Test("The newest flush of a rearmed pair is the one that pushes")
    func onlyTheNewestArmedFlushPasses() {
        let first = UUID()
        let second = UUID()
        #expect(CloudFlushGate.shouldFlush(isCancelled: false, currentToken: second, taskToken: first) == false)
        #expect(CloudFlushGate.shouldFlush(isCancelled: false, currentToken: second, taskToken: second))
    }
}
