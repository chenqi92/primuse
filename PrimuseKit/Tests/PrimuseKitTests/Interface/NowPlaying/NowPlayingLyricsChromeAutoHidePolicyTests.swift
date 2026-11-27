import Foundation
import Testing
@testable import PrimuseKit

@Suite struct NowPlayingLyricsChromeAutoHidePolicyTests {
    typealias Policy = NowPlayingLyricsChromeAutoHidePolicy

    /// 开着开关、正放着歌、看着竖屏歌词:可以开始倒计时。
    private static let ready = Policy.Conditions(
        isEnabled: true,
        showsLyrics: true,
        isImmersive: false,
        hostsCollapsibleLyrics: true,
        isSurfaceActive: true,
        isPlaying: true,
        hasLyrics: true,
        isVoiceOverRunning: false,
        isScrubbing: false,
        isCollapsed: false
    )

    private static func changing(_ change: (inout Policy.Conditions) -> Void) -> Policy.Conditions {
        var conditions = ready
        change(&conditions)
        return conditions
    }

    @Test func countsDownOnlyWhenEverythingAllows() {
        #expect(Policy.tracksActivity(Self.ready))
        #expect(Policy.mayAutoHide(Self.ready))
    }

    @Test func leavingTheCollapsibleLyricsPageStopsEverything() {
        let stops: [(inout Policy.Conditions) -> Void] = [
            { $0.isEnabled = false },
            { $0.showsLyrics = false },
            { $0.isImmersive = true },
            { $0.hostsCollapsibleLyrics = false },
            { $0.isSurfaceActive = false },
        ]
        for stop in stops {
            let conditions = Self.changing(stop)
            #expect(!Policy.tracksActivity(conditions))
            #expect(!Policy.mayAutoHide(conditions))
        }
    }

    @Test func pausedEmptyBusyOrCollapsedKeepsWatchingButDoesNotHide() {
        let holds: [(inout Policy.Conditions) -> Void] = [
            { $0.isPlaying = false },
            { $0.hasLyrics = false },
            { $0.isVoiceOverRunning = true },
            { $0.isScrubbing = true },
            { $0.isCollapsed = true },
        ]
        for hold in holds {
            let conditions = Self.changing(hold)
            #expect(Policy.tracksActivity(conditions))
            #expect(!Policy.mayAutoHide(conditions))
        }
    }

    @Test func remainingDelayCountsFromTheLastActivity() {
        #expect(Policy.remainingDelay(sinceLastActivity: 0, isInteracting: false) == Policy.idleDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: 1.5, isInteracting: false) == Policy.idleDelay - 1.5)
        #expect(Policy.remainingDelay(sinceLastActivity: Policy.idleDelay, isInteracting: false) == 0)
        #expect(Policy.remainingDelay(sinceLastActivity: 60, isInteracting: false) == 0)
    }

    @Test func anUnfinishedScrubOrABrokenClockWaitsAFullDelay() {
        #expect(Policy.remainingDelay(sinceLastActivity: 60, isInteracting: true) == Policy.idleDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: -3, isInteracting: false) == Policy.idleDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: .nan, isInteracting: false) == Policy.idleDelay)
        #expect(Policy.remainingDelay(sinceLastActivity: .infinity, isInteracting: false) == Policy.idleDelay)
    }
}
