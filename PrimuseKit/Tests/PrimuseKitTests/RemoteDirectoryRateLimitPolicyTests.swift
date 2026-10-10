import Foundation
import Testing
@testable import PrimuseKit

@Suite("列目录限流")
struct RemoteDirectoryRateLimitPolicyTests {
    @Test("只有 429 算限流, 503 不算")
    func onlyTooManyRequestsCounts() {
        #expect(RemoteDirectoryRateLimitPolicy.isRateLimited(statusCode: 429))
        #expect(!RemoteDirectoryRateLimitPolicy.isRateLimited(statusCode: 503))
        #expect(!RemoteDirectoryRateLimitPolicy.isRateLimited(statusCode: 500))
        #expect(!RemoteDirectoryRateLimitPolicy.isRateLimited(statusCode: 403))
        #expect(!RemoteDirectoryRateLimitPolicy.isRateLimited(statusCode: 207))
    }

    @Test("没有 Retry-After 时按阶梯等, 等完返回 nil")
    func fallbackLadderEndsInStop() {
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: nil) == 2)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 1, retryAfter: nil) == 5)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 2, retryAfter: nil) == 10)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 3, retryAfter: nil) == nil)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: -1, retryAfter: nil) == nil)
    }

    @Test("按服务端的 Retry-After 等, 至少 1 秒")
    func honoursRetryAfter() {
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: 7) == 7)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: 0.2) == 1)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 2, retryAfter: 30) == 30)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 3, retryAfter: 1) == nil)
    }

    @Test("要求等得太久就不硬等, 交给续扫")
    func longRetryAfterStopsTheScan() {
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: 31) == nil)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: 600) == nil)
    }

    @Test("Retry-After 无效时回到阶梯")
    func invalidRetryAfterFallsBack() {
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: 0) == 2)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 1, retryAfter: -3) == 5)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: .infinity) == 2)
        #expect(RemoteDirectoryRateLimitPolicy.delay(completedWaits: 0, retryAfter: .nan) == 2)
    }
}
