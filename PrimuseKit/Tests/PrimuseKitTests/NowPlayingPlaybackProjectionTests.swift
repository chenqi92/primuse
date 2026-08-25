import Testing
@testable import PrimuseKit

@Suite("Now Playing playback projection")
struct NowPlayingPlaybackProjectionTests {
    @Test("Playing exposes the selected rate and both transport commands")
    func projectsPlayingState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: true,
            preferredPlaybackRate: 1.5
        )

        #expect(projection.playbackRate == 1.5)
        #expect(projection.playCommandEnabled)
        #expect(projection.pauseCommandEnabled)
    }

    @Test("Paused exposes a zero rate and both transport commands")
    func projectsPausedState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: false,
            preferredPlaybackRate: 1.5
        )

        #expect(projection.playbackRate == 0)
        #expect(projection.playCommandEnabled)
        #expect(projection.pauseCommandEnabled)
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

    @Test("Loading with a current item keeps transport commands recoverable")
    func projectsLoadingState() {
        let projection = NowPlayingPlaybackProjectionPolicy.projection(
            hasCurrentItem: true,
            isPlaying: false,
            isLoading: true,
            preferredPlaybackRate: 1
        )

        #expect(projection.playbackRate == 0)
        #expect(projection.playCommandEnabled)
        #expect(projection.pauseCommandEnabled)
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

    @Test("Foreground activation recovers a suspended interruption exactly once")
    func foregroundActivationRecoversSuspendedInterruption() {
        var policy = PlaybackInterruptionResumePolicy()
        policy.registerPlayIntent()
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")

        let firstDecision = policy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: false,
            currentItemID: "song-a"
        )
        let repeatedDecision = policy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: false,
            currentItemID: "song-a"
        )

        #expect(firstDecision)
        #expect(!repeatedDecision)
    }

    @Test("Foreground activation waits while another app is still playing")
    func foregroundActivationDoesNotInterruptOtherAudio() {
        var policy = PlaybackInterruptionResumePolicy()
        policy.registerPlayIntent()
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")

        let foregroundDecision = policy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: true,
            currentItemID: "song-a"
        )
        let ticketRemainedPending = policy.isAwaitingInterruptionEnd
        let systemDecision = policy.interruptionEnded(
            systemShouldResume: true,
            currentItemID: "song-a"
        )

        #expect(!foregroundDecision)
        #expect(ticketRemainedPending)
        #expect(systemDecision)
    }

    @Test("A delayed duplicate begin preserves the original resume ticket")
    func suspendedDuplicateBeginPreservesResumeTicket() {
        var policy = PlaybackInterruptionResumePolicy()
        policy.registerPlayIntent()
        policy.interruptionBegan(wasActuallyPlaying: true, currentItemID: "song-a")

        policy.interruptionBegan(wasActuallyPlaying: false, currentItemID: "song-a")
        let ticketSurvivedDuplicate = policy.isAwaitingInterruptionEnd
        let foregroundDecision = policy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: false,
            currentItemID: "song-a"
        )

        #expect(ticketSurvivedDuplicate)
        #expect(foregroundDecision)
    }

    @Test("Foreground activation without an interruption ticket never starts playback")
    func foregroundActivationNeedsLiveTicket() {
        var policy = PlaybackInterruptionResumePolicy(playbackIsIntended: true)
        let foregroundDecision = policy.resumeAfterAppActivationIfSafe(
            otherAudioIsPlaying: false,
            currentItemID: "song-a"
        )

        #expect(!foregroundDecision)
    }
}

@Suite("Bluetooth playback recovery policy")
struct BluetoothPlaybackRecoveryPolicyTests {
    @Test("Only a Bluetooth profile switch bypasses disconnect pause")
    func profileSwitchDoesNotPause() {
        #expect(!BluetoothPlaybackRecoveryPolicy.shouldPauseForRouteLoss(
            reasonIsOldDeviceUnavailable: true,
            previousRouteWasBluetooth: true,
            currentRouteIsBluetooth: true
        ))
        #expect(BluetoothPlaybackRecoveryPolicy.shouldPauseForRouteLoss(
            reasonIsOldDeviceUnavailable: true,
            previousRouteWasBluetooth: true,
            currentRouteIsBluetooth: false
        ))
        #expect(BluetoothPlaybackRecoveryPolicy.shouldPauseForRouteLoss(
            reasonIsOldDeviceUnavailable: true,
            previousRouteWasBluetooth: false,
            currentRouteIsBluetooth: true
        ))
        #expect(!BluetoothPlaybackRecoveryPolicy.shouldPauseForRouteLoss(
            reasonIsOldDeviceUnavailable: false,
            previousRouteWasBluetooth: false,
            currentRouteIsBluetooth: false
        ))
    }

    @Test("Repeated notifications while HFP is active preserve the ticket")
    func hfpKeepsWaiting() {
        #expect(decision(isHFP: true) == .wait)
        #expect(decision(isHFP: false, isBluetooth: true) == .resume)
    }

    @Test("A pending system interruption keeps waiting after A2DP returns")
    func interruptionEndStillRequired() {
        #expect(decision(
            isHFP: false,
            isBluetooth: true,
            awaitingInterruptionEnd: true
        ) == .wait)
    }

    @Test("Route loss waits instead of consuming the ticket")
    func routeLossKeepsTicketUntilDisconnectHandlerCancelsIt() {
        #expect(decision(isHFP: false, isBluetooth: false) == .wait)
    }

    @Test("User intent, item identity and local ownership gate resume")
    func staleStateIsDiscarded() {
        #expect(decision(playbackIsIntended: false) == .discard)
        #expect(decision(itemMatches: false) == .discard)
        #expect(decision(supportsAutomaticRecovery: false) == .discard)
        #expect(decision(isPlaybackActuallyActive: true) == .discard)
    }

    @Test("No ticket has nothing to recover")
    func noTicketIsDiscarded() {
        #expect(decision(hasTicket: false) == .discard)
    }

    private func decision(
        hasTicket: Bool = true,
        isHFP: Bool = false,
        isBluetooth: Bool = true,
        playbackIsIntended: Bool = true,
        awaitingInterruptionEnd: Bool = false,
        isPlaybackActuallyActive: Bool = false,
        itemMatches: Bool = true,
        supportsAutomaticRecovery: Bool = true
    ) -> BluetoothDeferredResumeDecision {
        BluetoothPlaybackRecoveryPolicy.deferredResumeDecision(
            hasTicket: hasTicket,
            currentRouteIsBluetoothHFP: isHFP,
            currentRouteIsBluetooth: isBluetooth,
            playbackIsIntended: playbackIsIntended,
            isAwaitingInterruptionEnd: awaitingInterruptionEnd,
            isPlaybackActuallyActive: isPlaybackActuallyActive,
            suspendedItemMatchesCurrent: itemMatches,
            supportsAutomaticRecovery: supportsAutomaticRecovery
        )
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
