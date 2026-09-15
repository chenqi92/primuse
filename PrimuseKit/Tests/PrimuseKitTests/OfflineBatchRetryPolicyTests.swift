import Foundation
import Testing
@testable import PrimuseKit

@Suite("Offline batch retry policy")
struct OfflineBatchRetryPolicyTests {

    @Test("可重试的失败在用尽次数前一直重试")
    func retriesUntilAttemptsAreExhausted() {
        #expect(OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 1, isRetryable: true))
        #expect(OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 2, isRetryable: true))
    }

    @Test("第三次失败之后不再重试")
    func stopsAtMaximumAttempts() {
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 3, isRetryable: true))
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 9, isRetryable: true))
    }

    @Test("凭据/权限类失败一次都不重试")
    func neverRetriesUnrecoverableFailures() {
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 1, isRetryable: false))
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 2, isRetryable: false))
    }

    @Test("非法的尝试序号不触发重试")
    func rejectsNonPositiveAttempts() {
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: 0, isRetryable: true))
        #expect(!OfflineBatchRetryPolicy.shouldRetry(afterAttempt: -1, isRetryable: true))
    }

    @Test("退避是 2 秒起步的指数增长")
    func backoffGrowsExponentially() {
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 1, isRateLimited: false) == 2)
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 2, isRateLimited: false) == 4)
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 3, isRateLimited: false) == 8)
    }

    @Test("退避有上限，不会越等越离谱")
    func backoffIsCapped() {
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 6, isRateLimited: false) == 16)
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 40, isRateLimited: false) == 16)
    }

    @Test("服务端限流时至少等 30 秒")
    func rateLimitedWaitsLonger() {
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 1, isRateLimited: true) == 30)
        #expect(OfflineBatchRetryPolicy.retryDelay(afterAttempt: 2, isRateLimited: true) == 30)
    }

    @Test("一首歌在最坏情况下只会多等两轮退避")
    func totalWaitStaysBounded() {
        var total: TimeInterval = 0
        var attempt = 1
        while OfflineBatchRetryPolicy.shouldRetry(afterAttempt: attempt, isRetryable: true) {
            total += OfflineBatchRetryPolicy.retryDelay(afterAttempt: attempt, isRateLimited: false)
            attempt += 1
        }
        #expect(attempt == 3)
        #expect(total == 6)
    }
}
