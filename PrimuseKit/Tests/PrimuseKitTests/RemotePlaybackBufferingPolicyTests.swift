import Testing
@testable import PrimuseKit

@Suite("Remote playback rebuffering")
struct RemotePlaybackBufferingPolicyTests {
    private func action(
        eligible: Bool = true,
        enginePlaying: Bool = false,
        finished: Bool = false,
        duration: Double = 0,
        count: Int = 0,
        elapsed: Double? = nil,
        backpressured: Bool = false
    ) -> RemotePlaybackBufferingAction {
        RemotePlaybackBufferingPolicy.action(
            isEligible: eligible, engineIsPlaying: enginePlaying,
            decoderFinished: finished, bufferedDuration: duration,
            bufferCount: count, bufferingElapsed: elapsed, producerIsBackpressured: backpressured
        )
    }

    @Test("Slow Range responses retain the stream until audio arrives")
    func toleratesObservedNetworkDelays() {
        #expect(action(enginePlaying: true) == .begin)
        for elapsed in [0.5, 1, 7.5, 9.4, 12.6, 29.9] {
            #expect(action(elapsed: elapsed) == .wait)
        }
        #expect(action(duration: 5.9, count: 32, elapsed: 12.6) == .resume)
        #expect(action(enginePlaying: true, duration: 5.4, count: 29) == .none)
        // A later dropout has its own bounded refill window.
        #expect(action(enginePlaying: true) == .begin)
        #expect(action(elapsed: 1) == .wait)
    }

    @Test("Silent waiting is bounded without rebuilding or full-file download")
    func timesOutEmptyStream() {
        #expect(action(elapsed: 30) == .stop)
        #expect(action(elapsed: 600) == .stop)
        #expect(action(duration: 0, count: 1, elapsed: 30) == .stop)
        #expect(action(duration: .nan, count: 1, elapsed: 30) == .stop)
    }

    @Test("Refill builds a cushion but cannot deadlock on the PCM memory cap")
    func resumesAtRefillOrBackpressureLimit() {
        #expect(action(duration: 0.18, count: 1, elapsed: 0.5) == .wait)
        #expect(action(duration: 1, count: 6, elapsed: 1) == .resume)
        #expect(action(duration: 0.18, count: 1, elapsed: 3, backpressured: true) == .resume)
        #expect(action(duration: 0.43, count: 3, elapsed: 19) == .wait)
        #expect(action(duration: 0.43, count: 3, elapsed: 30) == .stop)
    }

    @Test("The final buffer outside the gate can finish while rebuffering")
    func drainsFinalTail() {
        #expect(action(finished: true, elapsed: 2) == .resume)
        #expect(action(finished: true, duration: 0.1, count: 1, elapsed: 1) == .resume)
        #expect(action(enginePlaying: true, finished: true) == .none)
    }

    @Test("User pause, seek, transitions and local playback never auto-resume")
    func respectsEligibilityAndStoppedEngine() {
        #expect(action(enginePlaying: false) == .none)
        for elapsed: Double? in [nil, 0, 12, 31] {
            #expect(action(eligible: false, enginePlaying: true, elapsed: elapsed) == .none)
            #expect(action(eligible: false, duration: 8, count: 43, elapsed: elapsed) == .none)
        }
    }
}
