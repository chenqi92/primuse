import Testing
@testable import PrimuseKit

@Suite("Now Playing playback projection")
struct NowPlayingPlaybackProjectionTests {
    @Test("Playing exposes the selected rate and only Pause")
    func projectsPlayingState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: true,
            preferredPlaybackRate: 1.5
        )

        #expect(projection.playbackRate == 1.5)
        #expect(!projection.playCommandEnabled)
        #expect(projection.pauseCommandEnabled)
    }

    @Test("Paused exposes a zero rate and only Play")
    func projectsPausedState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: false,
            preferredPlaybackRate: 1.5
        )

        #expect(projection.playbackRate == 0)
        #expect(projection.playCommandEnabled)
        #expect(!projection.pauseCommandEnabled)
    }

    @Test("No current item disables both commands")
    func projectsStoppedState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: false,
            isPlaying: true,
            preferredPlaybackRate: .infinity
        )

        #expect(projection.playbackRate == 0)
        #expect(!projection.playCommandEnabled)
        #expect(!projection.pauseCommandEnabled)
    }

    @Test("Loading is never projected as active playback")
    func projectsLoadingState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: true,
            isLoading: true,
            preferredPlaybackRate: 1
        )

        #expect(projection.playbackRate == 0)
        #expect(!projection.playCommandEnabled)
        #expect(!projection.pauseCommandEnabled)
    }

    @Test("An invalid playing rate falls back to normal speed")
    func sanitizesRate() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: true,
            preferredPlaybackRate: 0
        )

        #expect(projection.playbackRate == 1)
    }
}
