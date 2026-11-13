import Foundation
import Testing
@testable import PrimuseKit

@Suite("Remote transfer progress")
struct RemoteTransferProgressPolicyTests {

    @Test("数据还在到达时范围读取继续等")
    func slowTransferKeepsWaiting() {
        let deadline = RangeFetchDeadline(stallLimit: 30, totalLimit: 180)
        // 拿下载地址用了 15 秒，23 秒起每隔一两秒来一点数据（SYQ 慢网实测的形态）。
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: 26.8, now: 30.5) == .waiting)
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: 26.8, now: 56.7) == .waiting)
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: 26.8, now: 56.9) == .stalled)
    }

    @Test("一直没有动静按停滞结束")
    func silentTransferStalls() {
        let deadline = RangeFetchDeadline(stallLimit: 30, totalLimit: 180)
        #expect(deadline.verdict(startedAt: 100, lastActivityAt: nil, now: 129.9) == .waiting)
        #expect(deadline.verdict(startedAt: 100, lastActivityAt: nil, now: 130) == .stalled)
        // 开始之前的动静不算。
        #expect(deadline.verdict(startedAt: 100, lastActivityAt: 90, now: 130) == .stalled)
    }

    @Test("一直滴答来数据也有总上限")
    func tricklingTransferHitsTotalLimit() {
        let deadline = RangeFetchDeadline(stallLimit: 30, totalLimit: 180)
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: 179, now: 180) == .exceededLimit)
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: .nan, now: 10) == .waiting)
        #expect(deadline.verdict(startedAt: 0, lastActivityAt: nil, now: .infinity) == .stalled)
    }

    @Test("总上限不小于停滞时限")
    func totalLimitIsAtLeastStallLimit() {
        let deadline = RangeFetchDeadline(stallLimit: 40, totalLimit: 10)
        #expect(deadline.totalLimit == 40)
    }

    @Test("拿到读取错误时，断网立即判为连不上")
    func offlineAfterErrorIsNoConnection() {
        #expect(RemoteReadFailurePolicy.classify(
            now: 10, startedAt: 5, offlineSince: 9.9,
            lastConnectivityFailureAt: nil, lastSlowStallAt: nil, lastTransferAt: nil,
            minimumOfflineDuration: 0
        ) == .noConnection)
    }

    @Test("还在等的看门狗要断网持续几秒才下结论")
    func watchdogWaitsForSustainedOutage() {
        #expect(RemoteReadFailurePolicy.classify(
            now: 12, startedAt: 10, offlineSince: 10,
            lastConnectivityFailureAt: nil, lastSlowStallAt: nil, lastTransferAt: nil,
            minimumOfflineDuration: 3
        ) == nil)
        // 拖动之前就断网了（SYQ 断网续播）：开始等之后 3 秒就结束。
        #expect(RemoteReadFailurePolicy.classify(
            now: 13, startedAt: 10, offlineSince: 9.9,
            lastConnectivityFailureAt: nil, lastSlowStallAt: nil, lastTransferAt: nil,
            minimumOfflineDuration: 3
        ) == .noConnection)
    }

    @Test("断网后又收到数据说明路径状态落后，不按断网处理")
    func deliveryAfterOutageOverridesPathState() {
        #expect(RemoteReadFailurePolicy.classify(
            now: 20, startedAt: 10, offlineSince: 11,
            lastConnectivityFailureAt: nil, lastSlowStallAt: nil, lastTransferAt: 15,
            minimumOfflineDuration: 3
        ) == nil)
    }

    @Test("有网但取数因连不上失败且一直没收到数据，判为连不上")
    func connectivityFailureWithoutDelivery() {
        #expect(RemoteReadFailurePolicy.classify(
            now: 30, startedAt: 10, offlineSince: nil,
            lastConnectivityFailureAt: 29, lastSlowStallAt: nil, lastTransferAt: nil,
            minimumOfflineDuration: 0
        ) == .noConnection)
        // 开始之前的失败不算。
        #expect(RemoteReadFailurePolicy.classify(
            now: 30, startedAt: 10, offlineSince: nil,
            lastConnectivityFailureAt: 9, lastSlowStallAt: nil, lastTransferAt: nil,
            minimumOfflineDuration: 0
        ) == nil)
    }

    @Test("收到过数据但没能读完，判为太慢")
    func slowStallIsTooSlow() {
        #expect(RemoteReadFailurePolicy.classify(
            now: 60, startedAt: 10, offlineSince: nil,
            lastConnectivityFailureAt: nil, lastSlowStallAt: 59, lastTransferAt: 40,
            minimumOfflineDuration: 0
        ) == .tooSlow)
    }

    @Test("没网时连不上互联网不再按块重试")
    func chunkRetryStopsWhenOffline() {
        #expect(PlaybackChunkRetryPolicy.delay(
            isTransportFailure: true, failedAttempts: 1, elapsed: 0.2, networkUnavailable: true
        ) == nil)
        #expect(PlaybackChunkRetryPolicy.delay(
            isTransportFailure: true, failedAttempts: 1, elapsed: 0.2, networkUnavailable: false
        ) == 0.5)
    }
}

@Suite("Network path state", .serialized)
struct NetworkPathStateTests {
    @Test("记住最早的断网时刻，恢复后清掉")
    func recordsEarliestOutage() {
        defer { NetworkPathState.record(unsatisfied: false) }
        NetworkPathState.record(unsatisfied: false, now: 1)
        #expect(NetworkPathState.unavailableSince == nil)
        NetworkPathState.record(unsatisfied: true, now: 5)
        NetworkPathState.record(unsatisfied: true, now: 8)
        #expect(NetworkPathState.unavailableSince == 5)
        #expect(NetworkPathState.isUnavailable)
        NetworkPathState.record(unsatisfied: false, now: 9)
        #expect(!NetworkPathState.isUnavailable)
    }
}

@Suite("Request executor while offline")
struct RequestExecutorOfflineTests {
    private final class Attempts: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    private func run(networkUnavailable: Bool) async -> Int {
        let attempts = Attempts()
        let executor = RequestExecutor(
            policy: .init(maximumAttempts: 3, maximumRetryWait: 2),
            // Real sleeps: the executor's overall deadline also sleeps through
            // `timing`, and a no-op sleep would expire it at once.
            timing: .init(networkUnavailable: { networkUnavailable }),
            jitter: { _ in 0 }
        )
        _ = try? await executor.execute(replay: .idempotent, operation: { () async throws -> Int in
            _ = attempts.next()
            throw URLError(.notConnectedToInternet)
        })
        return attempts.count
    }

    @Test("没网时连不上互联网只请求一次")
    func doesNotRetryWhenOffline() async {
        #expect(await run(networkUnavailable: true) == 1)
    }

    @Test("有网时连不上互联网照旧重试")
    func retriesWhenNetworkIsUp() async {
        #expect(await run(networkUnavailable: false) == 3)
    }
}
