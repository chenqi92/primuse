import Foundation
import Testing
@testable import PrimuseKit

@Suite("Playback chunk retry policy")
struct PlaybackChunkRetryPolicyTests {

    @Test("连接层失败先等 0.5 秒、再等 1.5 秒")
    func retriesTransportFailuresWithBackoff() {
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 1, elapsed: 0.2) == 0.5)
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 2, elapsed: 1) == 1.5)
    }

    @Test("第三次失败后交给上层")
    func stopsAtMaximumAttempts() {
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 3, elapsed: 2) == nil)
    }

    @Test("非连接层失败一次都不重试")
    func neverRetriesServiceFailures() {
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: false, failedAttempts: 1, elapsed: 0) == nil)
    }

    @Test("超出重试窗口不再发起请求")
    func respectsForegroundDeadline() {
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 1, elapsed: 19.6) == nil)
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 1, elapsed: 60) == nil)
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 1, elapsed: .nan) == nil)
    }

    @Test("非法的失败次数不触发重试")
    func rejectsNonPositiveAttempts() {
        #expect(PlaybackChunkRetryPolicy.delay(isTransportFailure: true, failedAttempts: 0, elapsed: 0) == nil)
    }
}
