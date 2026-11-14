import Foundation
import Testing
@testable import PrimuseKit

struct ScreenIdleHoldPolicyTests {
    private let start = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func context(
        _ mode: ScreenIdleHoldMode,
        isAppActive: Bool = true,
        isImmersivePlayerShown: Bool = true,
        isPlaying: Bool = true,
        playbackStoppedAt: Date? = nil,
        requiresCharging: Bool = false,
        isCharging: Bool = false,
        lastInteractionAt: Date? = nil,
        minuteLength: TimeInterval = 60
    ) -> ScreenIdleHoldContext {
        ScreenIdleHoldContext(
            mode: mode,
            isAppActive: isAppActive,
            isImmersivePlayerShown: isImmersivePlayerShown,
            isPlaying: isPlaying,
            playbackStoppedAt: playbackStoppedAt,
            requiresCharging: requiresCharging,
            isCharging: isCharging,
            lastInteractionAt: lastInteractionAt ?? start,
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

    // MARK: - 只在沉浸画面上

    @Test func everyModeFollowsTheSystemAwayFromTheImmersivePlayer() {
        for mode in ScreenIdleHoldMode.allCases {
            let away = ScreenIdleHoldPolicy.decide(context(mode, isImmersivePlayerShown: false), now: start)
            #expect(away == .released)
        }
        // 充电、刚有过操作也一样：别的界面一律交给系统。
        let charging = context(.always, isImmersivePlayerShown: false, requiresCharging: true, isCharging: true)
        #expect(ScreenIdleHoldPolicy.decide(charging, now: start) == .released)
    }

    @Test func theImmersivePlayerKeepsEachModesTiming() {
        let always = ScreenIdleHoldPolicy.decide(context(.always), now: start.addingTimeInterval(8 * 3600))
        #expect(always == ScreenIdleHoldDecision(holds: true, reevaluateAt: nil))

        let tenMinutes = ScreenIdleHoldPolicy.decide(context(.extend10), now: start.addingTimeInterval(60))
        #expect(tenMinutes == ScreenIdleHoldDecision(holds: true, reevaluateAt: start.addingTimeInterval(10 * 60)))

        // 沉浸画面上照样要正在播放、App 在前台。
        #expect(!ScreenIdleHoldPolicy.decide(context(.always, isAppActive: false), now: start).holds)
        #expect(!ScreenIdleHoldPolicy.decide(context(.always, isPlaying: false), now: start).holds)
    }

    @Test func leavingTheImmersivePlayerDuringThePauseGraceLetsGoAtOnce() {
        let pausedAt = start.addingTimeInterval(60)
        let inside = context(.always, isPlaying: false, playbackStoppedAt: pausedAt)
        #expect(ScreenIdleHoldPolicy.decide(inside, now: pausedAt.addingTimeInterval(2)).holds)
        var outside = inside
        outside.isImmersivePlayerShown = false
        #expect(ScreenIdleHoldPolicy.decide(outside, now: pausedAt.addingTimeInterval(2)) == .released)
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
