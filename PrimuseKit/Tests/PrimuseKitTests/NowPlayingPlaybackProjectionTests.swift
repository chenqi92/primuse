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

    @Test("Loading with a current item keeps Play recoverable")
    func projectsLoadingState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: false,
            isLoading: true,
            preferredPlaybackRate: 1
        )

        #expect(projection.playbackRate == 0)
        #expect(projection.playCommandEnabled)
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

@Suite("Playback interruption resume policy")
struct PlaybackInterruptionResumePolicyTests {
    @Test("A track paused before interruption never resumes")
    func pausedBeforeInterruption() {
        var policy = PlaybackInterruptionResumePolicy()
        policy.interruptionBegan(wasActuallyPlaying: false, currentItemID: "song-a")

        let shouldResume = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        #expect(!shouldResume)
    }

    @Test("An actively playing unchanged item resumes exactly once")
    func resumesMatchingPlaybackOnce() {
        var policy = PlaybackInterruptionResumePolicy()
        policy.registerPlayIntent()
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")

        let firstDecision = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        let repeatedDecision = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        #expect(firstDecision)
        #expect(!repeatedDecision)
    }

    @Test("A user pause during interruption invalidates automatic resume")
    func pauseInvalidatesResume() {
        var policy = PlaybackInterruptionResumePolicy(playbackIsIntended: true)
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")
        policy.registerPauseOrStopIntent()

        let shouldResume = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )
        #expect(!shouldResume)
    }

    @Test("A replacement generation cannot be revived by an old callback")
    func replacementInvalidatesOldCallback() {
        var policy = PlaybackInterruptionResumePolicy(playbackIsIntended: true)
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")
        policy.invalidatePendingResumePreservingIntent()

        let shouldResume = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-b"
        )
        #expect(!shouldResume)
        #expect(policy.playbackIsIntended)
    }

    @Test("Other media ending without system permission leaves playback paused")
    func deniedResumeClearsPlaybackIntent() {
        var policy = PlaybackInterruptionResumePolicy(playbackIsIntended: true)
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")

        let shouldResume = policy.interruptionEnded(
            systemShouldResume: false,
            currentItemID: "song-a"
        )
        #expect(!shouldResume)
        #expect(!policy.playbackIsIntended)
    }
}

@Suite("Remote Play command policy")
struct RemotePlayCommandPolicyTests {
    @Test("A repeated Play command accepts one in-flight playback request")
    func loadingPlaybackIsIdempotent() {
        #expect(RemotePlayCommandPolicy.action(
            hasCurrentItem: true,
            isPlaybackActuallyActive: false,
            isLoading: true,
            playbackIsIntended: true
        ) == .awaitInFlightRequest)
    }

    @Test("A paused loading item is recoverable from system Play")
    func pausedLoadingPlaybackCanRetry() {
        #expect(RemotePlayCommandPolicy.action(
            hasCurrentItem: true,
            isPlaybackActuallyActive: false,
            isLoading: true,
            playbackIsIntended: false
        ) == .retryLoadingPlayback)
    }

    @Test("Actual playback and an empty item are idempotent terminal actions")
    func terminalActions() {
        #expect(RemotePlayCommandPolicy.action(
            hasCurrentItem: true,
            isPlaybackActuallyActive: true,
            isLoading: false,
            playbackIsIntended: true
        ) == .alreadyPlaying)
        #expect(RemotePlayCommandPolicy.action(
            hasCurrentItem: false,
            isPlaybackActuallyActive: false,
            isLoading: false,
            playbackIsIntended: false
        ) == .noActionableItem)
    }
}
