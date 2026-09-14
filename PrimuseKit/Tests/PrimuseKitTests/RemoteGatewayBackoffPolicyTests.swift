import Foundation
import Testing
@testable import PrimuseKit

@Suite("网关退让")
struct RemoteGatewayBackoffPolicyTests {
    @Test("只有 5xx 算网关失败")
    func onlyServerErrorsCount() {
        #expect(RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 500))
        #expect(RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 502))
        #expect(RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 503))
        #expect(RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 504))
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 200))
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 206))
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 404))
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 429))
    }

    @Test("服务器明确不支持的状态不值得退让")
    func unsupportedStatusesAreNotRetried() {
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 501))
        #expect(!RemoteGatewayBackoffPolicy.isGatewayFailure(statusCode: 505))
    }

    @Test("单发失败不退让, 从第二次起才降速")
    func firstFailureKeepsNormalCadence() {
        #expect(RemoteGatewayBackoffPolicy.delay(consecutiveFailures: 0) == 0)
        #expect(RemoteGatewayBackoffPolicy.delay(consecutiveFailures: 1) == 0)
        #expect(RemoteGatewayBackoffPolicy.delay(consecutiveFailures: 2) > 0)
        #expect(!RemoteGatewayBackoffPolicy.serializesReads(consecutiveFailures: 1))
        #expect(RemoteGatewayBackoffPolicy.serializesReads(consecutiveFailures: 2))
    }

    @Test("退让单调变长并封顶")
    func delayGrowsMonotonicallyAndSaturates() {
        var previous = RemoteGatewayBackoffPolicy.delay(consecutiveFailures: 1)
        for failures in 2...RemoteGatewayBackoffPolicy.maximumConsecutiveFailures {
            let delay = RemoteGatewayBackoffPolicy.delay(consecutiveFailures: failures)
            #expect(delay > previous)
            #expect(delay <= RemoteGatewayBackoffPolicy.maximumDelay)
            previous = delay
        }
        #expect(
            RemoteGatewayBackoffPolicy.delay(consecutiveFailures: 99)
                == RemoteGatewayBackoffPolicy.maximumDelay
        )
    }

    @Test("负数计数按零处理")
    func negativeCountsAreClamped() {
        #expect(RemoteGatewayBackoffPolicy.delay(consecutiveFailures: -3) == 0)
        #expect(RemoteGatewayBackoffPolicy.clampedFailureCount(-3) == 0)
        #expect(
            RemoteGatewayBackoffPolicy.clampedFailureCount(999)
                == RemoteGatewayBackoffPolicy.maximumConsecutiveFailures
        )
    }

    @Test("退让只落在失败的那个源上")
    func backoffIsScopedToOneSource() {
        var state = RemoteGatewayBackoffState()
        state.recordFailure(sourceID: "webdav")
        state.recordFailure(sourceID: "webdav")

        #expect(state.serializesReads(sourceID: "webdav"))
        #expect(state.delay(sourceID: "webdav") > 0)
        #expect(state.failureCount(sourceID: "nas") == 0)
        #expect(!state.serializesReads(sourceID: "nas"))
        #expect(state.delay(sourceID: "nas") == 0)
        #expect(state.backedOffSourceIDs == ["webdav"])
    }

    @Test("读到一次就撤掉退让")
    func successClearsBackoff() {
        var state = RemoteGatewayBackoffState()
        state.recordFailure(sourceID: "webdav")
        state.recordFailure(sourceID: "webdav")
        state.recordFailure(sourceID: "webdav")
        #expect(state.failureCount(sourceID: "webdav") == 3)

        state.recordSuccess(sourceID: "webdav")

        #expect(state.failureCount(sourceID: "webdav") == 0)
        #expect(!state.serializesReads(sourceID: "webdav"))
        #expect(state.delay(sourceID: "webdav") == 0)
        #expect(state.backedOffSourceIDs.isEmpty)
    }

    @Test("计数饱和后不再增长")
    func failureCountSaturates() {
        var state = RemoteGatewayBackoffState()
        var last = 0
        for _ in 0..<(RemoteGatewayBackoffPolicy.maximumConsecutiveFailures + 5) {
            last = state.recordFailure(sourceID: "webdav")
        }
        #expect(last == RemoteGatewayBackoffPolicy.maximumConsecutiveFailures)
        #expect(state.delay(sourceID: "webdav") == RemoteGatewayBackoffPolicy.maximumDelay)
    }

    @Test("手动重置立刻恢复正常节奏")
    func resetRestoresNormalCadence() {
        var state = RemoteGatewayBackoffState()
        state.recordFailure(sourceID: "webdav")
        state.recordFailure(sourceID: "nas")
        state.recordFailure(sourceID: "nas")

        state.reset(sourceID: "nas")
        #expect(state.failureCount(sourceID: "nas") == 0)
        #expect(state.failureCount(sourceID: "webdav") == 1)

        state.removeAll()
        #expect(state.backedOffSourceIDs.isEmpty)
    }
}
