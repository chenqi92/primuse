import Dispatch
import Foundation

/// 全屏效果的重绘帧率档位。只存本机、不进云同步：每台设备的屏幕刷新率不同。
public enum ImmersiveFrameRateMode: String, CaseIterable, Identifiable, Sendable {
    /// 各层沿用按 Apple TV 填充率调好的 12–24 帧，频谱每到一批采样画一次。
    case balanced
    case fps30
    case fps60
    /// 不设下限间隔，跟着屏幕刷新逐帧画（垂直同步）。
    case display

    public static let storageKey = "primuse.immersiveFrameRate"
    /// Mac 默认每秒 60 帧:屏幕多是 120Hz、多半插着电,按 Apple TV 填充率调的 12–24 帧在上面
    /// 一顿一顿的;低电量、发热时 `ImmersiveRenderBudget` 照样压回 30 帧。iPhone、iPad、电视仍是省电档。
    #if os(macOS)
    public static let defaultValue = ImmersiveFrameRateMode.fps60
    #else
    public static let defaultValue = ImmersiveFrameRateMode.balanced
    #endif

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    /// 设置里这一档的名字（本地化键）。
    public var titleKey: String {
        switch self {
        case .balanced: "immersive_frame_rate_balanced"
        case .fps30: "immersive_frame_rate_30"
        case .fps60: "immersive_frame_rate_60"
        case .display: "immersive_frame_rate_display"
        }
    }

    /// 渲染层 `TimelineView(.animation(minimumInterval:))` 的取值；`nil` 表示逐帧。
    /// 固定档只会让层变快，不会把本来就比它快的层拖慢。
    public func minimumInterval(base: TimeInterval) -> TimeInterval? {
        switch self {
        case .balanced: base
        case .fps30: min(base, 1.0 / 30.0)
        case .fps60: min(base, 1.0 / 60.0)
        case .display: nil
        }
    }

    /// 频谱的发布节奏。频谱环、声场地平线这类层不在 TimelineView 里，
    /// 每发布一次才重画一次，所以发布节奏就是它们的帧率。
    public func spectrumPacing(displayMaximumFramesPerSecond: Int) -> SpectrumPublishPacing {
        switch self {
        case .balanced:
            return .onArrival(pollInterval: 0.04)
        case .fps30:
            return .paced(interval: 1.0 / 30.0)
        case .fps60:
            return .paced(interval: 1.0 / 60.0)
        case .display:
            let framesPerSecond = min(max(displayMaximumFramesPerSecond, 30), 120)
            return .paced(interval: 1.0 / Double(framesPerSecond))
        }
    }
}

extension ImmersiveFrameRateMode {
    /// 60 帧与「跟随屏幕」：iPhone / iPad 的 ProMotion 屏会画到 120 帧，频谱分析也跟着变勤。
    public var isHighRefresh: Bool {
        self == .fps60 || self == .display
    }

    /// 从省电、30 帧换到 60 帧或跟随屏幕时先说明耗电，用户同意了才换。
    /// 已经在高帧率档之间换（60 帧 ↔ 跟随屏幕）不再问。
    public static func requiresConfirmation(from current: Self, to proposed: Self) -> Bool {
        proposed.isHighRefresh && !current.isHighRefresh
    }
}

/// 全屏效果画面动得多明显。只存本机、不进云同步：和帧率一样，每台设备愿意花的电不同。
///
/// 「标准」就是各效果原来调好的样子，不改任何数值。其余几档按倍数调三件事：按时间走的层
/// 动多快（星点漂移、声纹与极光起伏、封面墙滚动、轨道环），起伏多大（声纹、极光的波幅，
/// 封面流的呼吸），以及对声音多敏感（所有读频谱的层）。「拉满」再把粒子与星点加多一半。
public enum ImmersiveMotionIntensity: String, CaseIterable, Identifiable, Sendable {
    case subtle
    case standard
    case vivid
    case maximum

    public static let storageKey = "primuse.immersiveMotionIntensity"
    public static let defaultValue = ImmersiveMotionIntensity.standard

    public var id: String { rawValue }

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .defaultValue
    }

    /// 设置里这一档的名字（本地化键）。
    public var titleKey: String {
        switch self {
        case .subtle: "immersive_motion_intensity_subtle"
        case .standard: "immersive_motion_intensity_standard"
        case .vivid: "immersive_motion_intensity_vivid"
        case .maximum: "immersive_motion_intensity_maximum"
        }
    }

    /// 按时间走的层的速度倍数。唱片转速和模拟类效果（沙画、萤火、神经共鸣）的步长不跟这个走：
    /// 唱片转快了不像唱片，模拟步长放大会让结构散掉，它们靠下面的声音响应变得更活。
    public var speed: Double {
        switch self {
        case .subtle: 0.7
        case .standard: 1
        case .vivid: 1.5
        case .maximum: 2
        }
    }

    /// 起伏幅度的倍数。
    public var amplitude: Double {
        switch self {
        case .subtle: 0.7
        case .standard: 1
        case .vivid: 1.45
        case .maximum: 1.8
        }
    }

    /// 粒子、星点数量的倍数。只有「拉满」多画，其余档数量不变、开销不变。
    public var density: Double {
        self == .maximum ? 1.5 : 1
    }

    /// 频段先按指数抬（小于 1 时轻声也看得见起伏），再乘增益。
    var levelExponent: Double {
        switch self {
        case .subtle: 1.25
        case .standard: 1
        case .vivid: 0.8
        case .maximum: 0.65
        }
    }

    var levelGain: Double {
        switch self {
        case .subtle: 0.85
        case .standard: 1
        case .vivid: 1.15
        case .maximum: 1.3
        }
    }

    /// 「标准」原样返回频段，其余档按指数与增益重塑后夹在 0…1。只改形状，不凭空造信号：
    /// 没有频谱（全 0）时仍是 0。
    public func shapedLevel(_ level: Double) -> Double {
        guard self != .standard else { return level }
        guard level.isFinite, level > 0 else { return 0 }
        return min(1, pow(min(level, 1), levelExponent) * levelGain)
    }
}

/// 设备自己在省电或发热时，全屏效果临时降档。不改存下来的设置，条件解除就回到原来那档。
public enum ImmersiveDeviceConstraint: String, Equatable, Sendable {
    /// iPhone / iPad / Mac 打开了低电量模式。
    case lowPowerMode
    /// 系统报告的发热状态到了「严重」或「危急」。
    case thermal

    /// 两样都有时报低电量模式：那是用户自己打开的，说明里写它更好懂。
    public static func current(lowPowerModeEnabled: Bool, thermalStateIsSerious: Bool) -> Self? {
        if lowPowerModeEnabled { return .lowPowerMode }
        if thermalStateIsSerious { return .thermal }
        return nil
    }
}

/// 全屏页实际用的帧率与动效强度：选的档位经设备状态封顶之后的结果。
public struct ImmersiveRenderBudget: Equatable, Sendable {
    /// 降档时帧率最多到这一档，动效强度最多到「标准」。
    public static let constrainedFrameRateCeiling = ImmersiveFrameRateMode.fps30
    public static let constrainedIntensityCeiling = ImmersiveMotionIntensity.standard

    public let frameRate: ImmersiveFrameRateMode
    public let intensity: ImmersiveMotionIntensity
    /// 因为什么降的档；选的本来就不超过上限时为 nil，用不着提示。
    public let constraint: ImmersiveDeviceConstraint?
    public let lowersFrameRate: Bool
    public let lowersIntensity: Bool

    public init(
        selectedFrameRate: ImmersiveFrameRateMode,
        selectedIntensity: ImmersiveMotionIntensity,
        constraint: ImmersiveDeviceConstraint?
    ) {
        let lowersFrameRate = constraint != nil && selectedFrameRate.isHighRefresh
        let lowersIntensity = constraint != nil && Self.exceedsCeiling(selectedIntensity)
        self.frameRate = lowersFrameRate ? Self.constrainedFrameRateCeiling : selectedFrameRate
        self.intensity = lowersIntensity ? Self.constrainedIntensityCeiling : selectedIntensity
        self.lowersFrameRate = lowersFrameRate
        self.lowersIntensity = lowersIntensity
        self.constraint = lowersFrameRate || lowersIntensity ? constraint : nil
    }

    /// 真的被调低了才需要告诉用户。
    public var isLowered: Bool { constraint != nil }

    private static func exceedsCeiling(_ intensity: ImmersiveMotionIntensity) -> Bool {
        switch intensity {
        case .vivid, .maximum: true
        case .subtle, .standard: false
        }
    }
}

public enum SpectrumPublishPacing: Equatable, Sendable {
    /// 每到一批新采样就分析最新一窗并发布一次。
    case onArrival(pollInterval: TimeInterval)
    /// 按固定节奏发布，读取位置由 `SpectrumPlayoutCursor` 在每批采样之间匀速推进。
    case paced(interval: TimeInterval)

    public var pollInterval: TimeInterval {
        switch self {
        case .onArrival(let interval), .paced(let interval): interval
        }
    }

    /// 每秒最多发布 `framesPerSecond` 次：按固定节奏的档位放宽到这个间隔；
    /// 到一批发一批的（省电档每秒二十来次）本来就不超过，不变。
    public func limited(toFramesPerSecond framesPerSecond: Double) -> SpectrumPublishPacing {
        guard framesPerSecond > 0, case .paced(let interval) = self else { return self }
        return .paced(interval: max(interval, 1 / framesPerSecond))
    }
}

/// 音频回调写、后台轮询读的单声道采样环。写端只做拷贝并用 trylock，
/// 拿不到锁就丢掉这一批，绝不在音频线程上等锁。
public final class SpectrumSampleRing: @unchecked Sendable {
    public struct State: Equatable, Sendable {
        /// 自上次 reset 起累计写入的帧数，也是下一帧的绝对帧号。
        public let written: Int64
        /// 最近一批的帧数。
        public let latestBurst: Int
        /// 最近一批写入时的 `DispatchTime` 纳秒读数。
        public let arrivalUptime: UInt64

        public init(written: Int64, latestBurst: Int, arrivalUptime: UInt64) {
            self.written = written
            self.latestBurst = latestBurst
            self.arrivalUptime = arrivalUptime
        }
    }

    public let capacity: Int
    private let mask: Int
    private let storage: UnsafeMutablePointer<Float>
    private let lock = NSLock()
    private var written: Int64 = 0
    private var latestBurst = 0
    private var arrivalUptime: UInt64 = 0

    /// 容量取 2 的幂。默认 2^17 帧：192 kHz 下 400 ms 一批的 tap 也放得下，
    /// 还留着一窗 FFT 与回调抖动的余量。
    public init(capacityPowerOfTwo exponent: Int = 17) {
        capacity = 1 << max(exponent, 10)
        mask = capacity - 1
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// 写入一批采样，`stride` 用于交错格式（只取第一个声道）。超过容量时只留最新的部分。
    @discardableResult
    public func write(
        _ source: UnsafePointer<Float>,
        frameCount: Int,
        stride: Int = 1,
        uptimeNanoseconds: UInt64 = DispatchTime.now().uptimeNanoseconds
    ) -> Bool {
        guard frameCount > 0, stride > 0, lock.try() else { return false }
        defer { lock.unlock() }
        let kept = min(frameCount, capacity)
        let skipped = frameCount - kept
        var target = Int((written + Int64(skipped)) & Int64(mask))
        var offset = skipped
        var remaining = kept
        while remaining > 0 {
            let run = min(remaining, capacity - target)
            if stride == 1 {
                (storage + target).update(from: source + offset, count: run)
            } else {
                for index in 0..<run {
                    storage[target + index] = source[(offset + index) * stride]
                }
            }
            remaining -= run
            offset += run
            target = (target + run) & mask
        }
        written += Int64(frameCount)
        latestBurst = frameCount
        arrivalUptime = uptimeNanoseconds
        return true
    }

    public func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return State(written: written, latestBurst: latestBurst, arrivalUptime: arrivalUptime)
    }

    /// 把绝对帧号 `[end - count, end)` 拷进 `destination`；还没写到或已被覆盖的部分补零。
    public func copyWindow(endingAt end: Int64, count: Int, into destination: UnsafeMutablePointer<Float>) {
        guard count > 0 else { return }
        destination.update(repeating: 0, count: count)
        lock.lock()
        defer { lock.unlock() }
        let start = end - Int64(count)
        let lower = max(start, max(0, written - Int64(capacity)))
        let upper = min(end, written)
        guard upper > lower else { return }
        var source = Int(lower & Int64(mask))
        var target = Int(lower - start)
        var remaining = Int(upper - lower)
        while remaining > 0 {
            let run = min(remaining, capacity - source)
            (destination + target).update(from: storage + source, count: run)
            remaining -= run
            target += run
            source = (source + run) & mask
        }
    }

    public func reset() {
        lock.lock()
        defer { lock.unlock() }
        storage.update(repeating: 0, count: capacity)
        written = 0
        latestBurst = 0
        arrivalUptime = 0
    }
}

/// 把一批批到达的采样摊成按真实时间匀速前进的读取位置。
///
/// macOS 的混音器 tap 不管请求多大，都是约 100 ms 才回调一次（4800 帧）；只画
/// 「最新一批」时频谱一秒只有 10 个不同的画面。这里让读取位置落后最新采样一批
/// 再加一点余量，以最近一批的到达时刻为锚按墙上时钟前进，每帧都能取到不同的一窗。
public struct SpectrumPlayoutCursor: Sendable {
    /// 吸收回调抖动的余量。
    public static let jitterMargin: TimeInterval = 0.02

    private var lastEnd: Int64?
    private var observedWritten: Int64 = 0

    public init() {}

    /// 返回这一刻要分析的窗口终点（绝对帧号）与相对上次前进的帧数；
    /// 位置没往前走（等下一批、回调抖动）时返回 nil，调用方沿用上一帧。
    public mutating func advance(
        state: SpectrumSampleRing.State,
        nowUptime: UInt64,
        sampleRate: Double
    ) -> (end: Int64, advancedFrames: Int64)? {
        guard sampleRate.isFinite, sampleRate > 0,
              state.written > 0, state.latestBurst > 0 else { return nil }
        if state.written < observedWritten { lastEnd = nil }
        observedWritten = state.written

        let lead = Double(state.latestBurst) + sampleRate * Self.jitterMargin
        let sinceArrival = nowUptime > state.arrivalUptime
            ? Double(nowUptime - state.arrivalUptime) / 1_000_000_000
            : 0
        let position = min(
            Double(state.written) - lead + sinceArrival * sampleRate,
            Double(state.written)
        )
        let end = Int64(position.rounded(.down))
        guard end > 0 else { return nil }
        if let lastEnd {
            guard end > lastEnd else { return nil }
            self.lastEnd = end
            return (end, end - lastEnd)
        }
        lastEnd = end
        return (end, 0)
    }
}

/// 频段的时间平滑原本按「每次分析」取系数；分析频率变了以后按真实间隔折算，
/// 让起落速度与原来的节奏一致，不会因为画得更勤就变得更黏或更抖。
public enum SpectrumTemporalSmoothing {
    public static func blend(base: Float, elapsed: TimeInterval?, reference: TimeInterval) -> Float {
        guard let elapsed, elapsed.isFinite, elapsed > 0,
              reference > 0, base > 0, base < 1 else { return base }
        let exponent = Float(min(elapsed / reference, 8))
        return 1 - powf(1 - base, exponent)
    }
}

/// 全屏效果页长时间没人碰之后怎么省电。
///
/// 两档：「休憩」压暗画面、藏起控件、叠上时钟与当前歌词；「省电」再暗一档，装饰动画、实时频谱与动态封面
/// 都停下，只剩歌词与时钟跟着走。iPhone / iPad 5 分钟先进休憩、15 分钟进省电；Mac 与电视 15 分钟直接进省电。
/// 碰一下屏幕、按任意键就回到正常画面。亮色的画面（封面流的专辑色台面、白色主题色）在 OLED 屏上
/// 每个像素都在发光，压暗与停帧是这里省得最多的两处。
public enum ImmersiveIdlePowerPolicy {
    public enum Stage: Int, Comparable, Sendable {
        case awake
        case resting
        case lowPower

        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// iPhone / iPad 先进休憩的时间（原有的「休憩模式」）。
    public static let handheldRestDelay: TimeInterval = 5 * 60
    /// 进省电档的时间，从最后一次操作算起。
    public static let lowPowerDelay: TimeInterval = 15 * 60

    /// `stage` 之后的下一档；已是最后一档时为 nil。`restsEarly`：iPhone / iPad 先进休憩。
    public static func nextStage(after stage: Stage, restsEarly: Bool) -> Stage? {
        switch stage {
        case .awake: restsEarly ? .resting : .lowPower
        case .resting: .lowPower
        case .lowPower: nil
        }
    }

    /// 进入 `stage` 之后再等多久进下一档；已是最后一档时为 nil。
    public static func delayToNextStage(from stage: Stage, restsEarly: Bool) -> TimeInterval? {
        switch stage {
        case .awake: restsEarly ? handheldRestDelay : lowPowerDelay
        case .resting: restsEarly ? lowPowerDelay - handheldRestDelay : lowPowerDelay
        case .lowPower: nil
        }
    }

    /// 盖在舞台上的黑色不透明度：休憩压掉六成亮度，省电压掉八成。
    public static func dimOpacity(for stage: Stage) -> Double {
        switch stage {
        case .awake: 0
        case .resting: 0.60
        case .lowPower: 0.80
        }
    }

    /// 装饰动画、实时频谱与动态封面在这一档还跑不跑。
    public static func runsDecorativeMotion(in stage: Stage) -> Bool {
        stage != .lowPower
    }

    /// 休憩与省电时整幅画面隔一阵挪一小步（防烧屏），挪的那几秒缓缓过去，其余时间不重画。
    public static let driftStepInterval: TimeInterval = 60
    public static let driftStepDuration: TimeInterval = 8

    /// 第 `step` 步落在哪：四个角轮流走（±1，由容器乘上幅度），不会连着两步停在同一处。
    public static func driftOffset(step: Int) -> (x: Double, y: Double) {
        switch ((step % 4) + 4) % 4 {
        case 0: (-1, 1)
        case 1: (1, -1)
        case 2: (1, 1)
        default: (-1, -1)
        }
    }

    /// 电视：全屏效果开着时系统屏保是被挡住的；省电档里又暂停着，就把屏保交还给系统。
    public static func holdsScreenAwake(stage: Stage, isPlaying: Bool) -> Bool {
        stage != .lowPower || isPlaying
    }
}
