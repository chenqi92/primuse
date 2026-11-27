import Testing
@testable import PrimuseKit

struct OfflinePlaybackPolicyTests {
    @Test func cachedAudioSkipsRemoteSidecarVideoWhenDefinitelyOffline() {
        #expect(OfflinePlaybackPolicy.shouldSkipRemoteMusicVideo(
            hasUsableCachedAudio: true,
            isStandaloneMusicVideo: false,
            hasDeterminedNetworkPath: true,
            isNetworkReachable: false
        ))
    }

    @Test func standaloneVideoKeepsNormalRoutingButUnknownNetworkUsesCachedAudio() {
        #expect(!OfflinePlaybackPolicy.shouldSkipRemoteMusicVideo(
            hasUsableCachedAudio: true,
            isStandaloneMusicVideo: true,
            hasDeterminedNetworkPath: true,
            isNetworkReachable: false
        ))
        #expect(OfflinePlaybackPolicy.shouldSkipRemoteMusicVideo(
            hasUsableCachedAudio: true,
            isStandaloneMusicVideo: false,
            hasDeterminedNetworkPath: false,
            isNetworkReachable: false
        ))
    }

    @Test func completedOfflineFileBypassesStalePrefetchWait() {
        #expect(!OfflinePlaybackPolicy.shouldWaitForBackgroundCache(
            hasUsableCachedAudio: true,
            hasInFlightTask: true
        ))
        #expect(OfflinePlaybackPolicy.shouldWaitForBackgroundCache(
            hasUsableCachedAudio: false,
            hasInFlightTask: true
        ))
    }
}
