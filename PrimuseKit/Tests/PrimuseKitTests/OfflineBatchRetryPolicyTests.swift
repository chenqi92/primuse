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

@Suite("Offline batch failure breaker")
struct OfflineBatchFailureBreakerTests {

    @Test("同一个源连续三首连不上就不再开始这个源剩下的歌")
    func stopsSourceAfterConsecutiveConnectivityFailures() {
        var breaker = OfflineBatchFailureBreaker()
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        #expect(breaker.admits(sourceID: "nas"))
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        #expect(!breaker.admits(sourceID: "nas"))
        #expect(breaker.stoppedSources["nas"] == .sourceUnreachable)
        #expect(breaker.primaryStopReason == .sourceUnreachable)
    }

    @Test("中间成功一首就重新计数")
    func successResetsTheStreak() {
        var breaker = OfflineBatchFailureBreaker()
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordSuccess(sourceID: "nas")
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        #expect(breaker.admits(sourceID: "nas"))
        #expect(breaker.primaryStopReason == nil)
    }

    @Test("文件不在、单首报错说明源是通的，不计入连续失败")
    func perSongFailuresDoNotTripTheSource() {
        var breaker = OfflineBatchFailureBreaker()
        for _ in 0..<10 {
            breaker.recordFailure(sourceID: "nas", category: .other)
        }
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordFailure(sourceID: "nas", category: .accessDenied)
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        breaker.recordFailure(sourceID: "nas", category: .connectivity)
        #expect(breaker.admits(sourceID: "nas"))
    }

    @Test("账号失效连续出现时按登录失效停下")
    func authenticationStopsWithItsOwnReason() {
        var breaker = OfflineBatchFailureBreaker()
        for _ in 0..<3 {
            breaker.recordFailure(sourceID: "webdav", category: .authentication)
        }
        #expect(!breaker.admits(sourceID: "webdav"))
        #expect(breaker.stoppedSources["webdav"] == .sourceAuthentication)
    }

    @Test("一个源停下不影响别的源")
    func sourcesAreIndependent() {
        var breaker = OfflineBatchFailureBreaker()
        for _ in 0..<3 {
            breaker.recordFailure(sourceID: "nas", category: .connectivity)
        }
        breaker.recordFailure(sourceID: "cloud", category: .connectivity)
        #expect(!breaker.admits(sourceID: "nas"))
        #expect(breaker.admits(sourceID: "cloud"))
    }

    @Test("空间不够一次就停下整批")
    func storageStopsEverything() {
        var breaker = OfflineBatchFailureBreaker()
        breaker.recordFailure(sourceID: "nas", category: .storage)
        #expect(!breaker.admits(sourceID: "nas"))
        #expect(!breaker.admits(sourceID: "cloud"))
        #expect(breaker.primaryStopReason == .insufficientStorage)
    }

    @Test("整批停下的原因优先，先记下的不被覆盖")
    func deviceReasonWinsAndKeepsTheFirst() {
        var breaker = OfflineBatchFailureBreaker()
        for _ in 0..<3 {
            breaker.recordFailure(sourceID: "nas", category: .authentication)
        }
        breaker.stopAll(.networkUnavailable)
        breaker.recordFailure(sourceID: "cloud", category: .storage)
        #expect(breaker.primaryStopReason == .networkUnavailable)
    }

    @Test("几个源都停下时登录失效排在连不上前面")
    func authenticationOutranksUnreachable() {
        var breaker = OfflineBatchFailureBreaker()
        for _ in 0..<3 {
            breaker.recordFailure(sourceID: "a", category: .connectivity)
            breaker.recordFailure(sourceID: "b", category: .authentication)
        }
        #expect(breaker.primaryStopReason == .sourceAuthentication)
    }
}

@Suite("Offline batch network wait policy")
struct OfflineBatchNetworkWaitPolicyTests {

    @Test("断网导致的连接失败等网络回来再重来")
    func waitsWhenTheDeviceIsOffline() {
        #expect(OfflineBatchNetworkWaitPolicy.waitsForNetwork(
            category: .connectivity, deviceIsOffline: true, networkRetriesSoFar: 0
        ))
    }

    @Test("有网时的连接失败照常按重试次数走")
    func onlineConnectivityFailuresUseNormalRetries() {
        #expect(!OfflineBatchNetworkWaitPolicy.waitsForNetwork(
            category: .connectivity, deviceIsOffline: false, networkRetriesSoFar: 0
        ))
    }

    @Test("别的失败断网时也不等")
    func otherCategoriesNeverWait() {
        for category in OfflineBatchFailureCategory.allCases where category != .connectivity {
            #expect(!OfflineBatchNetworkWaitPolicy.waitsForNetwork(
                category: category, deviceIsOffline: true, networkRetriesSoFar: 0
            ))
        }
        #expect(!OfflineBatchNetworkWaitPolicy.waitsForNetwork(
            category: nil, deviceIsOffline: true, networkRetriesSoFar: 0
        ))
    }

    @Test("网络时断时续时同一首最多等几回")
    func networkRetriesAreBounded() {
        let limit = OfflineBatchNetworkWaitPolicy.maximumNetworkRetriesPerSong
        #expect(OfflineBatchNetworkWaitPolicy.waitsForNetwork(
            category: .connectivity, deviceIsOffline: true, networkRetriesSoFar: limit - 1
        ))
        #expect(!OfflineBatchNetworkWaitPolicy.waitsForNetwork(
            category: .connectivity, deviceIsOffline: true, networkRetriesSoFar: limit
        ))
    }
}

@Suite("Offline batch background run policy")
struct OfflineBatchBackgroundRunPolicyTests {

    @Test("两首以上、在前台发起时才申请系统任务")
    func requestsOnlyForRealBatchesStartedInForeground() {
        #expect(OfflineBatchBackgroundRunPolicy.requestsSystemTask(songCount: 300, isApplicationActive: true))
        #expect(OfflineBatchBackgroundRunPolicy.requestsSystemTask(songCount: 2, isApplicationActive: true))
        #expect(!OfflineBatchBackgroundRunPolicy.requestsSystemTask(songCount: 1, isApplicationActive: true))
        #expect(!OfflineBatchBackgroundRunPolicy.requestsSystemTask(songCount: 0, isApplicationActive: true))
        #expect(!OfflineBatchBackgroundRunPolicy.requestsSystemTask(songCount: 300, isApplicationActive: false))
    }

    @Test("系统收回时间时只有不在前台才停下这一批")
    func expirationCancelsOnlyInBackground() {
        #expect(OfflineBatchBackgroundRunPolicy.cancelsBatchOnExpiration(isApplicationActive: false))
        #expect(!OfflineBatchBackgroundRunPolicy.cancelsBatchOnExpiration(isApplicationActive: true))
    }

    @Test("进度按首数，不会超过总数")
    func progressUnitsAreClamped() {
        let midway = OfflineBatchBackgroundRunPolicy.progressUnits(handledCount: 120, totalCount: 300)
        #expect(midway.completed == 120)
        #expect(midway.total == 300)
        let overflow = OfflineBatchBackgroundRunPolicy.progressUnits(handledCount: 400, totalCount: 300)
        #expect(overflow.completed == 300)
        let empty = OfflineBatchBackgroundRunPolicy.progressUnits(handledCount: -1, totalCount: 0)
        #expect(empty.completed == 0)
        #expect(empty.total == 1)
    }
}
