import Foundation
import Observation
import PrimuseKit
#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass
#elseif os(tvOS)
import SwiftUI
import UIKit
#elseif os(macOS)
import AppKit
import IOKit.pwr_mgt
#endif

/// 屏幕常亮的租约登记处。播放时屏幕常亮、电视全屏播放页、传输页、卡拉OK麦克风各持一份，
/// 最后一份放手才把锁屏 / 屏保交还系统。系统的常亮开关只在这里写：各处不再自己存旧值、还旧值，
/// 免得一处「还原」把另一处正拿着的常亮关掉。
@MainActor
enum ScreenWakeLeases {
    private static var owners: Set<String> = []
    private static var isApplied = false
    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #endif

    static func update(owner: String, holds: Bool) {
        let updated = ScreenWakeLeasePolicy.updatedOwners(owners, owner: owner, holds: holds)
        guard updated != owners else { return }
        owners = updated
        apply(!owners.isEmpty)
    }

    private static func apply(_ hold: Bool) {
        guard hold != isApplied else { return }
        isApplied = hold
        plog("screen wake lease hold=\(hold) owners=\(owners.sorted().joined(separator: ","))")
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = hold
        #elseif os(macOS)
        if hold {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "Primuse keeps the display on while playing"
            )
        } else {
            if let activity { ProcessInfo.processInfo.endActivity(activity) }
            activity = nil
            restartSystemIdleCountdown()
        }
        #endif
    }

    #if os(macOS)
    /// 放手的这一刻记一次用户活动：系统的屏保与显示器睡眠从现在起按它自己的时长重新计，
    /// 和 iPhone、电视把锁屏计时交还系统时一样。不这样的话已经闲了很久，一放手就立刻黑屏，
    /// 延时档等于没有。断言由系统按显示器睡眠时长自己收回。
    private static func restartSystemIdleCountdown() {
        var assertionID: IOPMAssertionID = 0
        _ = IOPMAssertionDeclareUserActivity(
            "Primuse returned the display to the system" as CFString,
            kIOPMUserActiveLocal,
            &assertionID
        )
    }
    #endif
}

/// 播放时屏幕常亮（`ScreenIdleHoldMode`）：三端同一份判定（`ScreenIdleHoldPolicy`），这里只管收集输入、
/// 拿放租约和到点重算。只在正在播放且 App 在前台时拿；延时档无操作满时长后放手；暂停后回到系统规则。
/// 设置只存在这台设备上（不登记 iCloud 键值同步）。
@MainActor
@Observable
final class ScreenIdleHoldController {
    static let shared = ScreenIdleHoldController()

    /// 电视一直常亮：在静止页面停够了，根视图看到它变了就转到播放页（`TVScreenIdleRestModifier`）。
    private(set) var playerSurfaceRequest = 0

    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var readsIsPlaying: @MainActor @Sendable () -> Bool = { false }
    @ObservationIgnored private var mode = ScreenIdleHoldMode.defaultValue
    @ObservationIgnored private var requiresCharging = false
    @ObservationIgnored private var isCharging = false
    @ObservationIgnored private var isAppActive = false
    @ObservationIgnored private var isPlaying = false
    @ObservationIgnored private var playbackStoppedAt: Date?
    @ObservationIgnored private var lastInteractionAt = Date()
    @ObservationIgnored private var isOnPlayerSurface = false
    @ObservationIgnored private var fullscreenPageOwners: Set<String> = []
    @ObservationIgnored private var lastSurfaceRequestFor: Date?
    @ObservationIgnored private var resumesOnInteraction = false
    @ObservationIgnored private var holdsForPlayback = false
    @ObservationIgnored private var holdsForFullscreenPage = false
    @ObservationIgnored private var reevaluation: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []

    private static let playbackOwner = "playback"
    private static let fullscreenPageOwner = "fullscreenPage"
    #if os(macOS)
    /// Mac 读的是整机的最近输入：放手以后隔这么久看一眼，有人动过就重新拿。
    private static let macResumePollInterval: TimeInterval = 15
    #endif

    private init() {}

    /// 启动时调一次。`isPlaying` 在观察里读，播放状态一变就重算。
    func start(isPlaying: @escaping @MainActor @Sendable () -> Bool) {
        guard !isStarted else { return }
        isStarted = true
        if Self.debugFakesPlayback {
            readsIsPlaying = { true }
        } else {
            readsIsPlaying = isPlaying
        }
        migrateLegacySettingIfNeeded()
        loadSettings()
        observeSystem()
        refreshAppActive()
        observePlayback()
        evaluate()
    }

    /// 设置页改了档位或「仅在充电时」。改设置本身也算一次操作。
    func settingsDidChange() {
        loadSettings()
        lastInteractionAt = Date()
        #if os(iOS)
        installTouchObserversIfNeeded()
        #endif
        evaluate()
    }

    /// 触摸、遥控、键盘之外的地方（电视全屏页的方向键、遥控播放键）报一次操作。
    func noteUserInteraction() {
        lastInteractionAt = Date()
        // 正拿着时只记时间，到点的重算会按新时间往后推；已经因为没人操作放手了就马上重新拿。
        if resumesOnInteraction { evaluate() }
    }

    /// 电视：是否停在播放页上（画面是动的）。
    func setPlayerSurfaceVisible(_ visible: Bool) {
        guard visible != isOnPlayerSurface else { return }
        isOnPlayerSurface = visible
        evaluate()
    }

    /// 电视全屏播放页原有的那份租约（`TVImmersiveScreenWakePolicy` 算好再交进来）。
    func updateFullscreenPage(owner: String, holds: Bool) {
        let updated = ScreenWakeLeasePolicy.updatedOwners(fullscreenPageOwners, owner: owner, holds: holds)
        guard updated != fullscreenPageOwners else { return }
        fullscreenPageOwners = updated
        evaluate()
    }

    // MARK: - 判定

    private var minuteLength: TimeInterval { Self.debugMinuteLength ?? 60 }

    private func currentContext(now: Date) -> ScreenIdleHoldContext {
        var lastInteraction = lastInteractionAt
        #if os(macOS)
        lastInteraction = max(lastInteraction, Self.systemLastInputAt(now: now))
        #endif
        #if os(tvOS)
        let limitsStaticPages = true
        #else
        let limitsStaticPages = false
        #endif
        return ScreenIdleHoldContext(
            mode: mode,
            isAppActive: isAppActive,
            isPlaying: isPlaying,
            playbackStoppedAt: playbackStoppedAt,
            requiresCharging: requiresCharging,
            isCharging: isCharging,
            lastInteractionAt: lastInteraction,
            isOnPlayerSurface: isOnPlayerSurface,
            limitsStaticPages: limitsStaticPages,
            minuteLength: minuteLength
        )
    }

    private func evaluate() {
        reevaluation?.cancel()
        reevaluation = nil
        #if os(iOS)
        refreshBatteryMonitoring()
        #endif
        let now = Date()
        let context = currentContext(now: now)
        let playback = ScreenIdleHoldPolicy.decide(context, now: now)
        let fullscreenPage = ScreenIdleHoldPolicy.fullscreenPageDecision(
            mode: mode,
            pageHolds: !fullscreenPageOwners.isEmpty,
            lastInteractionAt: context.lastInteractionAt,
            now: now,
            minuteLength: minuteLength
        )
        var deadlines = [playback.reevaluateAt, fullscreenPage.reevaluateAt].compactMap { $0 }

        if let requestAt = ScreenIdleHoldPolicy.playerSurfaceRequestTime(for: context) {
            if now >= requestAt {
                if lastSurfaceRequestFor != context.lastInteractionAt {
                    lastSurfaceRequestFor = context.lastInteractionAt
                    playerSurfaceRequest &+= 1
                    plog("screen idle: static page for \(Int(now.timeIntervalSince(context.lastInteractionAt)))s, asking for the player")
                }
            } else {
                deadlines.append(requestAt)
            }
        }

        // 是不是只因为没人操作才没拿：有人一碰就要马上重新拿。
        var fresh = context
        fresh.lastInteractionAt = now
        resumesOnInteraction = (!playback.holds && ScreenIdleHoldPolicy.decide(fresh, now: now).holds)
            || (!fullscreenPage.holds && !fullscreenPageOwners.isEmpty)
        #if os(macOS)
        if resumesOnInteraction {
            deadlines.append(now.addingTimeInterval(Self.macResumePollInterval))
        }
        #endif

        if playback.holds != holdsForPlayback || fullscreenPage.holds != holdsForFullscreenPage {
            let idleSeconds = Int(now.timeIntervalSince(context.lastInteractionAt))
            let nextSeconds = deadlines.min().map { Int($0.timeIntervalSince(now)) } ?? -1
            plog("screen idle mode=\(mode.rawValue) active=\(isAppActive) playing=\(isPlaying) idle=\(idleSeconds)s playbackHold=\(playback.holds) fullscreenHold=\(fullscreenPage.holds) next=\(nextSeconds)s")
        }
        holdsForPlayback = playback.holds
        holdsForFullscreenPage = fullscreenPage.holds
        ScreenWakeLeases.update(owner: Self.playbackOwner, holds: playback.holds)
        ScreenWakeLeases.update(owner: Self.fullscreenPageOwner, holds: fullscreenPage.holds)

        guard let next = deadlines.min() else { return }
        let delay = max(0.5, next.timeIntervalSince(now) + 0.05)
        reevaluation = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.evaluate()
        }
    }

    // MARK: - 输入

    private func loadSettings() {
        let defaults = UserDefaults.standard
        mode = ScreenIdleHoldMode(storedValue: defaults.string(forKey: ScreenIdleHoldMode.storageKey))
        #if os(iOS)
        requiresCharging = defaults.object(forKey: PlayerAppearancePreferences.playerScreenWakeRequiresChargingKey) == nil
            ? PlayerAppearancePreferences.playerScreenWakeRequiresChargingByDefault
            : defaults.bool(forKey: PlayerAppearancePreferences.playerScreenWakeRequiresChargingKey)
        #endif
    }

    /// 旧版 iPhone / iPad 开着「播放器界面保持屏幕常亮」：第一次启动新版时写成一直常亮。
    /// 「仅在充电时」本来就沿用同一个键。
    private func migrateLegacySettingIfNeeded() {
        #if os(iOS)
        let defaults = UserDefaults.standard
        guard let migrated = ScreenIdleHoldMode.migratedValue(
            storedValue: defaults.string(forKey: ScreenIdleHoldMode.storageKey),
            legacyKeepsScreenAwake: defaults.bool(forKey: ScreenIdleHoldMode.legacyKeepsScreenAwakeKey)
        ) else { return }
        defaults.set(migrated.rawValue, forKey: ScreenIdleHoldMode.storageKey)
        plog("screen idle: migrated the player keep-awake toggle to \(migrated.rawValue)")
        #endif
    }

    private func observePlayback() {
        let playing = withObservationTracking {
            readsIsPlaying()
        } onChange: {
            // 单例常驻，不用捕获 self。
            Task { @MainActor in ScreenIdleHoldController.shared.observePlayback() }
        }
        playbackChanged(playing)
    }

    private func playbackChanged(_ playing: Bool) {
        guard playing != isPlaying else { return }
        let now = Date()
        isPlaying = playing
        if playing {
            // 停了一阵又开始放（耳机键、Siri、点播放）也是人发起的；切歌途中的短暂停顿不算。
            let resumedAfterBreak = playbackStoppedAt.map {
                now.timeIntervalSince($0) >= ScreenIdleHoldPolicy.pauseGrace
            } ?? true
            if resumedAfterBreak { lastInteractionAt = now }
            playbackStoppedAt = nil
        } else {
            playbackStoppedAt = now
        }
        evaluate()
    }

    /// - Parameter inactiveScene: 正要失去活跃的场景。通知发出时它的状态还没改，要先排除掉。
    private func refreshAppActive(excluding inactiveScene: ObjectIdentifier? = nil) {
        let active: Bool
        #if os(iOS) || os(tvOS)
        active = UIApplication.shared.connectedScenes.contains { scene in
            ObjectIdentifier(scene) != inactiveScene
                && scene.activationState == .foregroundActive
                && scene.session.role == .windowApplication
        }
        #elseif os(macOS)
        active = Self.debugAssumesActive
            || (NSApp.occlusionState.contains(.visible) && !NSApp.isHidden)
        #endif
        guard active != isAppActive else { return }
        isAppActive = active
        // 回到前台算一次操作，计时从这一刻起。
        if active { lastInteractionAt = Date() }
        #if os(iOS)
        if active { installTouchObserversIfNeeded() }
        #endif
        evaluate()
    }

    private func observeSystem() {
        let center = NotificationCenter.default
        /// 处理器拿到的是通知对象的标识（场景通知要排除发通知的那个场景），不把通知本身带进主线程隔离域。
        func observe(_ name: Notification.Name, _ handler: @escaping @MainActor @Sendable (ObjectIdentifier?) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { note in
                let sender = note.object.map { ObjectIdentifier($0 as AnyObject) }
                MainActor.assumeIsolated { handler(sender) }
            }
            observers.append(token)
        }
        #if os(iOS) || os(tvOS)
        observe(UIScene.didActivateNotification) { [weak self] _ in self?.refreshAppActive() }
        observe(UIScene.willDeactivateNotification) { [weak self] scene in
            self?.refreshAppActive(excluding: scene)
        }
        observe(UIScene.didEnterBackgroundNotification) { [weak self] _ in self?.refreshAppActive() }
        // 遥控器方向键、滑动挪了焦点（电视上的主要操作）。切页、弹窗、控件自己收起时程序挪的焦点
        // 没有方向，不算操作，否则每换一首歌、播放页每收一次控件都会把计时拨回去。
        let focusToken = center.addObserver(
            forName: UIFocusSystem.didUpdateNotification, object: nil, queue: .main
        ) { [weak self] note in
            nonisolated(unsafe) let notification = note
            MainActor.assumeIsolated {
                let context = notification.userInfo?[UIFocusSystem.focusUpdateContextUserInfoKey]
                    as? UIFocusUpdateContext
                guard let context, !context.focusHeading.isEmpty else { return }
                self?.noteUserInteraction()
            }
        }
        observers.append(focusToken)
        // 推到边上挪不动也算按过。
        observe(UIFocusSystem.movementDidFailNotification) { [weak self] _ in self?.noteUserInteraction() }
        #endif
        #if os(iOS)
        observe(UIWindow.didBecomeKeyNotification) { [weak self] _ in self?.installTouchObserversIfNeeded() }
        observe(UIDevice.batteryStateDidChangeNotification) { [weak self] _ in
            guard let self else { return }
            let charging = Self.deviceIsCharging
            guard charging != isCharging else { return }
            isCharging = charging
            evaluate()
        }
        #elseif os(macOS)
        observe(NSApplication.didChangeOcclusionStateNotification) { [weak self] _ in self?.refreshAppActive() }
        observe(NSApplication.didHideNotification) { [weak self] _ in self?.refreshAppActive() }
        observe(NSApplication.didUnhideNotification) { [weak self] _ in self?.refreshAppActive() }
        observe(NSApplication.didBecomeActiveNotification) { [weak self] _ in self?.noteUserInteraction() }
        #endif
    }

    #if os(iOS)
    /// 只在需要拿租约的档位上挂：跟随系统（默认）的用户窗口上什么也不多。
    private func installTouchObserversIfNeeded() {
        guard mode.holdsWhilePlaying else { return }
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene,
                  windowScene.session.role == .windowApplication else { continue }
            for window in windowScene.windows
            where !(window.gestureRecognizers ?? []).contains(where: { $0 is ScreenIdleTouchObserver }) {
                let observer = ScreenIdleTouchObserver(target: nil, action: nil)
                observer.cancelsTouchesInView = false
                observer.delaysTouchesBegan = false
                observer.delaysTouchesEnded = false
                observer.requiresExclusiveTouchType = false
                observer.onTouch = { [weak self] in self?.noteUserInteraction() }
                window.addGestureRecognizer(observer)
            }
        }
    }

    /// `batteryState` 只在开着电量监测时才是真值：只在「仅在充电时」这条规则用得上的时候开。
    private func refreshBatteryMonitoring() {
        let wantsMonitoring = mode.holdsWhilePlaying && requiresCharging && isAppActive
        let device = UIDevice.current
        if device.isBatteryMonitoringEnabled != wantsMonitoring {
            device.isBatteryMonitoringEnabled = wantsMonitoring
        }
        if wantsMonitoring { isCharging = Self.deviceIsCharging }
    }

    private static var deviceIsCharging: Bool {
        switch UIDevice.current.batteryState {
        case .charging, .full: true
        case .unplugged, .unknown: false
        @unknown default: false
        }
    }
    #endif

    #if os(macOS)
    /// 整机最近一次键盘、鼠标、触控板输入：屏保与显示器睡眠看的也是它。
    private static func systemLastInputAt(now: Date) -> Date {
        guard let anyInput = CGEventType(rawValue: ~0) else { return .distantPast }
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle.isFinite, idle >= 0 else { return .distantPast }
        return now.addingTimeInterval(-idle)
    }
    #endif

    // MARK: - 调试钩子

    /// `PRIMUSE_DEBUG_SCREEN_IDLE_MINUTE_SECONDS=4`：一「分钟」按 4 秒算，延长 5 分钟 = 20 秒，模拟器上看得到放手。
    private static var debugMinuteLength: TimeInterval? {
        #if DEBUG
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SCREEN_IDLE_MINUTE_SECONDS"]
            .flatMap(Double.init).flatMap { $0 > 0 ? $0 : nil }
        #else
        nil
        #endif
    }

    /// `PRIMUSE_DEBUG_SCREEN_IDLE_FAKE_PLAYING=1`：当作一直在播放，不用真放歌就能看租约。
    private static var debugFakesPlayback: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SCREEN_IDLE_FAKE_PLAYING"] == "1"
        #else
        false
        #endif
    }

    /// `PRIMUSE_DEBUG_SCREEN_IDLE_ASSUME_ACTIVE=1`（Mac）：锁着屏的编译机上窗口算不上可见，测试时当作可见。
    private static var debugAssumesActive: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_SCREEN_IDLE_ASSUME_ACTIVE"] == "1"
        #else
        false
        #endif
    }
}

#if os(iOS)
/// 只看不抢：手指一落下就记一次操作，随即判失败，不参与任何点按、滚动、长按的判定。
private final class ScreenIdleTouchObserver: UIGestureRecognizer {
    var onTouch: (@MainActor () -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        onTouch?()
        state = .failed
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
#endif

#if os(tvOS)
/// 电视根视图：报告是否停在播放页；一直常亮时在静止页面停够了就转到播放页（动态画面，
/// 全屏页还有省电与防烧屏漂移），盖着别的全屏页转不过去时由判定自己放手交给系统屏保。
struct TVScreenIdleRestModifier: ViewModifier {
    let isOnPlayerSurface: Bool
    let canOpenPlayer: Bool
    let openPlayer: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: isOnPlayerSurface, initial: true) { _, visible in
                ScreenIdleHoldController.shared.setPlayerSurfaceVisible(visible)
            }
            .onChange(of: ScreenIdleHoldController.shared.playerSurfaceRequest) { _, _ in
                guard canOpenPlayer else { return }
                openPlayer()
            }
    }
}
#endif
