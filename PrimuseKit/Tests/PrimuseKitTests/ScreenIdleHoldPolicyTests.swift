import Foundation
import Testing
@testable import PrimuseKit

struct ScreenIdleHoldPolicyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func context(
        _ mode: ScreenIdleHoldMode,
        isAppActive: Bool = true,
        isPlaying: Bool = true,
        playbackStoppedAt: Date? = nil,
        requiresCharging: Bool = false,
        isCharging: Bool = false,
        lastInteractionAt: Date? = nil,
        isOnPlayerSurface: Bool = false,
        limitsStaticPages: Bool = false,
        minuteLength: TimeInterval = 60
    ) -> ScreenIdleHoldContext {
        ScreenIdleHoldContext(
            mode: mode,
            isAppActive: isAppActive,
            isPlaying: isPlaying,
            playbackStoppedAt: playbackStoppedAt,
            requiresCharging: requiresCharging,
            isCharging: isCharging,
            lastInteractionAt: lastInteractionAt ?? start,
            isOnPlayerSurface: isOnPlayerSurface,
            limitsStaticPages: limitsStaticPages,
            minuteLength: minuteLength
        )
    }

    // MARK: - 取值

    @Test func storedValuesResolveAndUnknownOnesFallBackToFollowingTheSystem() {
        #expect(ScreenIdleHoldMode(storedValue: nil) == .system)
        #expect(ScreenIdleHoldMode(storedValue: "") == .system)
        #expect(ScreenIdleHoldMode(storedValue: "extend45") == .system)
        for mode in ScreenIdleHoldMode.allCases {
            #expect(ScreenIdleHoldMode(storedValue: mode.rawValue) == mode)
        }
        #expect(ScreenIdleHoldMode.defaultValue == .system)
        #expect(!ScreenIdleHoldMode.storageKey.contains("."))
    }

    @Test func extensionsAreOrderedAndOnlyTheDelayModesHaveADuration() {
        let minutes = ScreenIdleHoldMode.allCases.compactMap(\.extensionMinutes)
        #expect(minutes == [5, 10, 15, 30, 60])
        #expect(ScreenIdleHoldMode.system.extensionMinutes == nil)
        #expect(ScreenIdleHoldMode.always.extensionMinutes == nil)
        #expect(!ScreenIdleHoldMode.system.holdsWhilePlaying)
        #expect(ScreenIdleHoldMode.allCases.filter(\.holdsWhilePlaying).count == 6)
        #expect(Set(ScreenIdleHoldMode.allCases.map(\.titleKey)).count == ScreenIdleHoldMode.allCases.count)
    }

    // MARK: - 迁移

    @Test func theOldPlayerToggleMigratesToAlwaysOnOnlyOnce() {
        #expect(ScreenIdleHoldMode.migratedValue(storedValue: nil, legacyKeepsScreenAwake: true) == .always)
        #expect(ScreenIdleHoldMode.migratedValue(storedValue: nil, legacyKeepsScreenAwake: false) == nil)
        // 新设置存过就不再看旧开关（用户之后自己改成别的档不能被改回去）。
        #expect(ScreenIdleHoldMode.migratedValue(storedValue: "system", legacyKeepsScreenAwake: true) == nil)
        #expect(ScreenIdleHoldMode.migratedValue(storedValue: "extend10", legacyKeepsScreenAwake: true) == nil)
        #expect(ScreenIdleHoldMode.legacyKeepsScreenAwakeKey == "primuse.player.keepsScreenAwakeForLyrics")
    }

    // MARK: - 基础条件

    @Test func followingTheSystemNeverHolds() {
        let decision = ScreenIdleHoldPolicy.decide(context(.system), now: start)
        #expect(decision == .released)
    }

    @Test func alwaysOnHoldsWhilePlayingInTheForegroundWithoutADeadline() {
        let decision = ScreenIdleHoldPolicy.decide(
            context(.always),
            now: start.addingTimeInterval(6 * 3600)
        )
        #expect(decision == ScreenIdleHoldDecision(holds: true, reevaluateAt: nil))
        #expect(!ScreenIdleHoldPolicy.decide(context(.always, isAppActive: false), now: start).holds)
    }

    // MARK: - 计时放行

    @Test func delayModesReleaseAfterTheChosenIdleTime() {
        let ten = context(.extend10)
        let early = ScreenIdleHoldPolicy.decide(ten, now: start.addingTimeInterval(9 * 60))
        #expect(early.holds)
        #expect(early.reevaluateAt == start.addingTimeInterval(10 * 60))
        #expect(!ScreenIdleHoldPolicy.decide(ten, now: start.addingTimeInterval(10 * 60)).holds)
        #expect(!ScreenIdleHoldPolicy.decide(ten, now: start.addingTimeInterval(3600)).holds)

        let hour = context(.extend60)
        #expect(ScreenIdleHoldPolicy.decide(hour, now: start.addingTimeInterval(59 * 60)).holds)
        #expect(!ScreenIdleHoldPolicy.decide(hour, now: start.addingTimeInterval(60 * 60)).holds)
    }

    @Test func anyInteractionRestartsTheDelay() {
        let touchedLater = context(.extend5, lastInteractionAt: start.addingTimeInterval(4 * 60))
        let decision = ScreenIdleHoldPolicy.decide(touchedLater, now: start.addingTimeInterval(8 * 60))
        #expect(decision.holds)
        #expect(decision.reevaluateAt == start.addingTimeInterval(9 * 60))
    }

    @Test func theDebugMinuteLengthScalesTheDelay() {
        let quick = context(.extend5, minuteLength: 4)
        #expect(ScreenIdleHoldPolicy.decide(quick, now: start.addingTimeInterval(19)).holds)
        #expect(!ScreenIdleHoldPolicy.decide(quick, now: start.addingTimeInterval(20)).holds)
    }

    // MARK: - 暂停放行

    @Test func pausingHandsTheScreenBackAfterAShortGrace() {
        let pausedAt = start.addingTimeInterval(60)
        let paused = context(.always, isPlaying: false, playbackStoppedAt: pausedAt)
        let duringGrace = ScreenIdleHoldPolicy.decide(paused, now: pausedAt.addingTimeInterval(3))
        #expect(duringGrace.holds)
        #expect(duringGrace.reevaluateAt == pausedAt.addingTimeInterval(ScreenIdleHoldPolicy.pauseGrace))
        #expect(!ScreenIdleHoldPolicy.decide(
            paused,
            now: pausedAt.addingTimeInterval(ScreenIdleHoldPolicy.pauseGrace)
        ).holds)

        // 这次启动还没播过：没有宽限可言。
        #expect(!ScreenIdleHoldPolicy.decide(context(.always, isPlaying: false), now: start).holds)
    }

    @Test func theEarlierOfGraceEndAndDelayExpiryIsTheNextCheck() {
        let pausedAt = start.addingTimeInterval(4 * 60 + 55)
        let paused = context(.extend5, isPlaying: false, playbackStoppedAt: pausedAt)
        let decision = ScreenIdleHoldPolicy.decide(paused, now: pausedAt.addingTimeInterval(1))
        #expect(decision.holds)
        #expect(decision.reevaluateAt == start.addingTimeInterval(5 * 60))
    }

    // MARK: - 充电约束

    @Test func chargingOnlyReleasesOnBattery() {
        #expect(!ScreenIdleHoldPolicy.decide(
            context(.always, requiresCharging: true, isCharging: false), now: start
        ).holds)
        #expect(ScreenIdleHoldPolicy.decide(
            context(.always, requiresCharging: true, isCharging: true), now: start
        ).holds)
        #expect(ScreenIdleHoldPolicy.decide(
            context(.extend15, requiresCharging: false, isCharging: false), now: start
        ).holds)
    }

    // MARK: - 电视静止页面

    @Test func tvAlwaysOnAsksForThePlayerAfterAStaticStretchAndLetsGoIfItCannot() {
        let staticPage = context(.always, limitsStaticPages: true)
        let rest = start.addingTimeInterval(ScreenIdleHoldPolicy.staticPageRestMinutes * 60)
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(for: staticPage) == rest)
        let atRest = ScreenIdleHoldPolicy.decide(staticPage, now: rest)
        #expect(atRest.holds)
        #expect(atRest.reevaluateAt == rest.addingTimeInterval(ScreenIdleHoldPolicy.staticPageReleaseGrace))
        #expect(!ScreenIdleHoldPolicy.decide(
            staticPage,
            now: rest.addingTimeInterval(ScreenIdleHoldPolicy.staticPageReleaseGrace)
        ).holds)

        // 已经在播放页上：一直常亮没有上限，也不再请求转页。
        let onPlayer = context(.always, isOnPlayerSurface: true, limitsStaticPages: true)
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(for: onPlayer) == nil)
        #expect(ScreenIdleHoldPolicy.decide(onPlayer, now: start.addingTimeInterval(8 * 3600)).holds)
    }

    @Test func onlyTVAlwaysOnRequestsThePlayer() {
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(for: context(.always)) == nil)
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(for: context(.extend30, limitsStaticPages: true)) == nil)
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(
            for: context(.always, isPlaying: false, limitsStaticPages: true)
        ) == nil)
        #expect(ScreenIdleHoldPolicy.playerSurfaceRequestTime(
            for: context(.always, isAppActive: false, limitsStaticPages: true)
        ) == nil)
        // 延时档在电视静止页面照用户选的时长，不另加上限。
        #expect(ScreenIdleHoldPolicy.decide(
            context(.extend30, limitsStaticPages: true),
            now: start.addingTimeInterval(29 * 60)
        ).holds)
    }

    // MARK: - 电视全屏播放页

    @Test func theTVFullscreenPageKeepsItsOldHoldUnlessADelayIsChosen() {
        let later = start.addingTimeInterval(3 * 3600)
        #expect(ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: .system, pageHolds: true, lastInteractionAt: start, now: later
        ) == ScreenIdleHoldDecision(holds: true, reevaluateAt: nil))
        #expect(ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: .always, pageHolds: true, lastInteractionAt: start, now: later
        ).holds)
        #expect(ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: .system, pageHolds: false, lastInteractionAt: start, now: start
        ) == .released)

        let fifteen = ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: .extend15, pageHolds: true, lastInteractionAt: start, now: start.addingTimeInterval(60)
        )
        #expect(fifteen == ScreenIdleHoldDecision(holds: true, reevaluateAt: start.addingTimeInterval(15 * 60)))
        #expect(!ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: .extend15, pageHolds: true, lastInteractionAt: start, now: start.addingTimeInterval(15 * 60)
        ).holds)
    }

    // MARK: - 多个持有者

    @Test func theScreenStaysAwakeUntilTheLastOwnerLetsGo() {
        var owners: Set<String> = []
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "playback", holds: true)
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "transfer", holds: true)
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "playback", holds: true)
        #expect(owners == ["playback", "transfer"])
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "playback", holds: false)
        #expect(owners == ["transfer"])
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "fullscreen", holds: false)
        #expect(owners == ["transfer"])
        owners = ScreenWakeLeasePolicy.updatedOwners(owners, owner: "transfer", holds: false)
        #expect(owners.isEmpty)

        let window = UUID()
        var ids: Set<UUID> = ScreenWakeLeasePolicy.updatedOwners([], owner: window, holds: true)
        ids = ScreenWakeLeasePolicy.updatedOwners(ids, owner: window, holds: false)
        #expect(ids.isEmpty)
    }
}
