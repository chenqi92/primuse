import Foundation

/// 播放时屏幕常亮：iPhone / iPad、Mac、Apple TV 同一个设置，只对这台设备生效、不随 iCloud 同步。
/// 只在沉浸（全屏）播放画面上起作用，别的界面一律跟随系统；设置也就放在沉浸模式里，不在播放设置里。
///
/// 系统不许 App 改自己的自动锁屏 / 屏保 / 显示器睡眠时长，所以延时档的做法是 App 先拦住屏幕，
/// 无操作满所选时长后放手，之后系统再按它自己的时长接手：实际进入时间是两段相加，不会比系统设置更短。
public enum ScreenIdleHoldMode: String, CaseIterable, Sendable, Identifiable {
    /// 跟随系统：各端原来的行为（电视全屏播放页播放时照旧挡住屏保）。
    case system
    case extend5
    case extend10
    case extend15
    case extend30
    case extend60
    /// 沉浸画面上播放期间一直不进锁屏 / 屏保。
    case always

    /// 键名不带点号：带点号的 @AppStorage 会被 standard 上任何一次写入叫醒。
    public static let storageKey = "screenIdleHoldMode"
    public static let defaultValue: ScreenIdleHoldMode = .system
    /// 旧版 iPhone / iPad 的「播放器界面保持屏幕常亮」开关。
    public static let legacyKeepsScreenAwakeKey = "primuse.player.keepsScreenAwakeForLyrics"

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    /// 延时档 App 拦多少分钟；跟随系统与一直常亮没有时长。
    public var extensionMinutes: Int? {
        switch self {
        case .extend5: 5
        case .extend10: 10
        case .extend15: 15
        case .extend30: 30
        case .extend60: 60
        case .system, .always: nil
        }
    }

    /// 除了跟随系统，沉浸画面上播放时 App 都要拿一份常亮租约。
    public var holdsWhilePlaying: Bool { self != .system }

    public var titleKey: String {
        switch self {
        case .system: "screen_idle_follow_system"
        case .extend5: "screen_idle_extend_5"
        case .extend10: "screen_idle_extend_10"
        case .extend15: "screen_idle_extend_15"
        case .extend30: "screen_idle_extend_30"
        case .extend60: "screen_idle_extend_60"
        case .always: "screen_idle_always"
        }
    }

    /// 新设置还没存过时，旧开关开着的迁移成一直常亮；「仅在充电时」沿用原来的键，不用迁移。
    /// 返回 nil 表示什么也不用写。
    public static func migratedValue(
        storedValue: String?,
        legacyKeepsScreenAwake: Bool
    ) -> ScreenIdleHoldMode? {
        guard storedValue == nil, legacyKeepsScreenAwake else { return nil }
        return .always
    }
}

/// 判定这一刻要不要拿着常亮租约所需的全部输入。
public struct ScreenIdleHoldContext: Equatable, Sendable {
    public var mode: ScreenIdleHoldMode
    /// iPhone / iPad / 电视：App 在前台且是活跃的；Mac：Primuse 的窗口在屏幕上看得见。
    public var isAppActive: Bool
    /// 沉浸（全屏）播放画面正显示着：iPhone / iPad 的全屏效果页与全屏歌词（含外接屏上的全屏效果页）、
    /// Mac 主窗口进了系统全屏、电视的播放页（正在播放时占满全屏，全屏效果页也盖在它上面）。
    /// 屏幕常亮只在这时才有意义，别的界面一律跟随系统。
    public var isImmersivePlayerShown: Bool
    public var isPlaying: Bool
    /// 最近一次从播放变成没在播的时刻；还在播、或这次启动还没播过是 nil。
    public var playbackStoppedAt: Date?
    /// iPhone / iPad 的「仅在充电时」。
    public var requiresCharging: Bool
    public var isCharging: Bool
    /// 最近一次用户操作（触摸、遥控、键盘鼠标、开始播放、改设置、回到前台、进沉浸画面）。
    public var lastInteractionAt: Date
    /// 一「分钟」有多少秒。只有调试钩子会改小它，正式版恒为 60。
    public var minuteLength: TimeInterval

    public init(
        mode: ScreenIdleHoldMode,
        isAppActive: Bool,
        isImmersivePlayerShown: Bool,
        isPlaying: Bool,
        playbackStoppedAt: Date? = nil,
        requiresCharging: Bool = false,
        isCharging: Bool = false,
        lastInteractionAt: Date,
        minuteLength: TimeInterval = 60
    ) {
        self.mode = mode
        self.isAppActive = isAppActive
        self.isImmersivePlayerShown = isImmersivePlayerShown
        self.isPlaying = isPlaying
        self.playbackStoppedAt = playbackStoppedAt
        self.requiresCharging = requiresCharging
        self.isCharging = isCharging
        self.lastInteractionAt = lastInteractionAt
        self.minuteLength = minuteLength
    }
}

public struct ScreenIdleHoldDecision: Equatable, Sendable {
    public var holds: Bool
    /// 没有新输入时判定最早会自己变的时刻（延时档到点、暂停宽限结束）；nil 表示不会自己变。
    public var reevaluateAt: Date?

    public init(holds: Bool, reevaluateAt: Date?) {
        self.holds = holds
        self.reevaluateAt = reevaluateAt
    }

    public static let released = ScreenIdleHoldDecision(holds: false, reevaluateAt: nil)
}

public enum ScreenIdleHoldPolicy {
    /// 暂停后再拿这么久才放手：切歌、缓冲时播放状态会短暂变成「没在播」，不能让屏幕跟着闪一下锁屏计时。
    public static let pauseGrace: TimeInterval = 10

    /// 「播放时屏幕常亮」这份租约：只在沉浸画面显示着、正在播放（含暂停后的短暂宽限）且 App 在前台时拿；
    /// 延时档无操作满时长后放手，暂停、离开沉浸画面后回到系统规则。
    ///
    /// 以前在任何页面播放都拿，电视一直常亮还得在静止页面停够 15 分钟时转到播放页防烧屏；
    /// 现在别的页面本来就交给系统屏保，那一套不再需要。
    public static func decide(_ context: ScreenIdleHoldContext, now: Date) -> ScreenIdleHoldDecision {
        guard context.mode.holdsWhilePlaying, context.isAppActive, context.isImmersivePlayerShown else {
            return .released
        }
        guard !context.requiresCharging || context.isCharging else { return .released }

        var deadlines: [Date] = []
        if !context.isPlaying {
            guard let stoppedAt = context.playbackStoppedAt else { return .released }
            let graceEnd = stoppedAt.addingTimeInterval(pauseGrace)
            guard now < graceEnd else { return .released }
            deadlines.append(graceEnd)
        }
        if let minutes = context.mode.extensionMinutes {
            let expiry = context.lastInteractionAt.addingTimeInterval(Double(minutes) * context.minuteLength)
            guard now < expiry else { return .released }
            deadlines.append(expiry)
        }
        return ScreenIdleHoldDecision(holds: true, reevaluateAt: deadlines.min())
    }

    /// 电视全屏播放页自己的那份租约（省电档又暂停时交还系统，由 `pageHolds` 带进来）。
    /// 跟随系统与一直常亮照旧；选了延时档就同样无操作满时长后放手。
    public static func fullscreenPageDecision(
        mode: ScreenIdleHoldMode,
        pageHolds: Bool,
        lastInteractionAt: Date,
        now: Date,
        minuteLength: TimeInterval = 60
    ) -> ScreenIdleHoldDecision {
        guard pageHolds else { return .released }
        guard let minutes = mode.extensionMinutes else {
            return ScreenIdleHoldDecision(holds: true, reevaluateAt: nil)
        }
        let expiry = lastInteractionAt.addingTimeInterval(Double(minutes) * minuteLength)
        return now < expiry ? ScreenIdleHoldDecision(holds: true, reevaluateAt: expiry) : .released
    }
}

/// 屏幕常亮的租约：播放时屏幕常亮、电视全屏播放页、传输页、卡拉OK麦克风各持一份，
/// 最后一份放手才把锁屏 / 屏保交还系统。
public enum ScreenWakeLeasePolicy {
    public static func updatedOwners<Owner: Hashable>(
        _ owners: Set<Owner>,
        owner: Owner,
        holds: Bool
    ) -> Set<Owner> {
        var updated = owners
        if holds {
            updated.insert(owner)
        } else {
            updated.remove(owner)
        }
        return updated
    }
}
