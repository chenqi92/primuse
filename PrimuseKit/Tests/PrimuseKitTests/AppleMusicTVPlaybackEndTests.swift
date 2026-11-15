import Testing
@testable import PrimuseKit

@Suite("Apple Music TV playback end")
struct AppleMusicTVPlaybackEndTests {
    @Test(arguments: [0.0, 0.000192, 0.081337, 1.3])
    func startupClockDoesNotFinishSong(_ time: Double) {
        #expect(!AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: false, isStopped: true, hasCurrentEntry: false,
            duration: 230.66, furthestObservedTime: time
        ))
    }

    @Test(arguments: [0.081337, 1.3, 100.0])
    func prematureStopDoesNotAdvance(_ time: Double) {
        #expect(!AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: true, hasCurrentEntry: false,
            duration: 230.66, furthestObservedTime: time
        ))
    }

    @Test func naturalEndWithClearedClockAndEntryAdvances() {
        #expect(AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: true, hasCurrentEntry: false,
            duration: 230.66, furthestObservedTime: 230.4
        ))
    }

    @Test func pauseNearEndDoesNotAdvance() {
        #expect(!AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: false, hasCurrentEntry: false,
            duration: 230.66, furthestObservedTime: 230.4
        ))
    }

    @Test func remainingQueueEntryDoesNotFinishQueue() {
        #expect(!AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: true, hasCurrentEntry: true,
            duration: 230.66, furthestObservedTime: 230.4
        ))
    }

    @Test func missingDurationNeedsSustainedPlayback() {
        #expect(!AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: true, hasCurrentEntry: false,
            duration: 0, furthestObservedTime: 0.08
        ))
        #expect(AppleMusicTVPlaybackPolicy.didFinishPlayback(
            hasObservedPlayingState: true, isStopped: true, hasCurrentEntry: false,
            duration: 0, furthestObservedTime: 30
        ))
    }
}
