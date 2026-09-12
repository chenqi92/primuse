import Testing
@testable import PrimuseKit

@Suite("Watch state ticker policy")
struct WatchStateTickerPolicyTests {
    @Test("Playback keeps the ticker running")
    func runsWhilePlaying() {
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: true,
            isLoading: false,
            hasCurrentSong: true
        ))
    }

    @Test("Loading keeps the ticker running even before audio starts")
    func runsWhileLoading() {
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: false,
            isLoading: true,
            hasCurrentSong: true
        ))
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: false,
            isLoading: true,
            hasCurrentSong: false
        ))
    }

    @Test("A paused song stops the ticker — its state is pushed on the transition")
    func stopsWhilePaused() {
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: false,
            isLoading: false,
            hasCurrentSong: true
        ) == false)
    }

    @Test("An idle player with no song stops the ticker")
    func stopsWhileIdle() {
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: false,
            isLoading: false,
            hasCurrentSong: false
        ) == false)
    }

    @Test("Playing with no resolved song still ticks, so a starting track is not missed")
    func runsWhilePlayingWithoutSong() {
        #expect(WatchStateTickerPolicy.shouldRunTicker(
            isPlaying: true,
            isLoading: true,
            hasCurrentSong: false
        ))
    }
}
