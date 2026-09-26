import Foundation

/// iPhone Duo 这类折叠屏合上、展开时（窗口从外屏换到内屏，或反过来），整屏做一次归位过渡：
/// 内容从轻微模糊、沿开合方向略微拉伸、略微变淡的样子平滑回到原样，像系统自己的开合效果那样
/// 「锁定在空间里」；页面里的元素照旧各自滑到新位置。
///
/// 只认「换了一块屏幕」：窗口所在的屏幕变了，或者 iPhone 上的画布在「常规宽 + 常规高」（Duo 内屏）
/// 与其它之间翻转、而且前后都铺满整块屏幕。普通 iPhone 转屏（Pro Max 横屏是常规宽 + 紧凑高）、
/// Duo 同一块屏幕上转屏、分屏多任务里拖宽拖窄、iPad 都不算。
public enum ScreenChangeTransitionPolicy {
    /// 某一刻窗口所在的画布。
    public struct Canvas: Equatable, Sendable {
        /// 窗口所在屏幕的标识；拿不到时为 nil（只按画布翻转判定）。
        public var screenID: Int?
        public var width: Double
        public var height: Double
        public var screenWidth: Double
        public var screenHeight: Double
        public var isRegularWidth: Bool
        public var isRegularHeight: Bool
        public var isPhone: Bool

        public init(
            screenID: Int?,
            width: Double,
            height: Double,
            screenWidth: Double,
            screenHeight: Double,
            isRegularWidth: Bool,
            isRegularHeight: Bool,
            isPhone: Bool
        ) {
            self.screenID = screenID
            self.width = width
            self.height = height
            self.screenWidth = screenWidth
            self.screenHeight = screenHeight
            self.isRegularWidth = isRegularWidth
            self.isRegularHeight = isRegularHeight
            self.isPhone = isPhone
        }

        /// iPhone 上常规宽 + 常规高的画布：只有折叠屏展开（Duo 内屏）才会这样，普通 iPhone 横屏是紧凑高。
        public var isExpanded: Bool {
            isPhone && isRegularWidth && isRegularHeight
        }

        /// 窗口铺满了整块屏幕（不在分屏里）。屏幕尺寸可能按另一个朝向报，宽高互换也算。
        public var fillsScreen: Bool {
            guard width > 0, height > 0, screenWidth > 0, screenHeight > 0 else { return false }
            let tolerance = 1.0
            let same = abs(width - screenWidth) <= tolerance && abs(height - screenHeight) <= tolerance
            let swapped = abs(width - screenHeight) <= tolerance && abs(height - screenWidth) <= tolerance
            return same || swapped
        }
    }

    public enum Axis: Equatable, Sendable {
        /// 书本式开合（Duo 的铰链是竖的）：画布横向变宽或变窄。
        case horizontal
        case vertical
    }

    public struct Change: Equatable, Sendable {
        /// 沿哪个方向拉伸：画布变化大的那一边。
        public var axis: Axis
        /// 换到了更大的屏幕（展开）。
        public var isUnfolding: Bool
    }

    /// 从上一次的画布换到这一次，算不算换了一块屏幕；算的话给出拉伸方向。
    public static func change(from previous: Canvas?, to current: Canvas) -> Change? {
        guard let previous, previous.isPhone, current.isPhone else { return nil }
        let screenChanged = previous.screenID != nil
            && current.screenID != nil
            && previous.screenID != current.screenID
        let canvasFlipped = previous.isExpanded != current.isExpanded
            && previous.fillsScreen
            && current.fillsScreen
        guard screenChanged || canvasFlipped else { return nil }
        let widthChange = abs(current.width - previous.width)
        let heightChange = abs(current.height - previous.height)
        return Change(
            axis: widthChange >= heightChange ? .horizontal : .vertical,
            isUnfolding: current.width * current.height > previous.width * previous.height
        )
    }

    // MARK: - 过渡的样子

    /// 从开始归位到回到原样的时长（秒）。有铰链读数时归位接在系统的开合过渡之后，略放慢一点看得出来。
    public static let duration: Double = 0.55
    /// 接在系统过渡之后开始时（内容已经是清楚的），先用这么久（秒）淡进起点，不硬切到模糊。
    public static let rampInDuration: Double = 0.07
    /// 起点的模糊半径（点）。
    public static let blurRadius: Double = 14
    /// 起点沿开合方向多拉伸的比例。
    public static let stretch: Double = 0.05
    /// 起点的不透明度。
    public static let dimmedOpacity: Double = 0.88
    /// 开了减弱动态效果：不模糊、不拉伸，只做这么短的一次淡入。
    public static let reducedMotionDuration: Double = 0.2
    public static let reducedMotionOpacity: Double = 0.55

    /// 过渡走到 `progress`（1 是换屏那一刻，0 是回到原样）时的样子。
    public struct Frame: Equatable, Sendable {
        public var scaleX: Double
        public var scaleY: Double
        public var blurRadius: Double
        public var opacity: Double
    }

    public static func frame(progress: Double, axis: Axis, reduceMotion: Bool) -> Frame {
        let p = progress.isFinite ? min(max(progress, 0), 1) : 0
        if reduceMotion {
            return Frame(scaleX: 1, scaleY: 1, blurRadius: 0, opacity: 1 - (1 - reducedMotionOpacity) * p)
        }
        let scale = 1 + stretch * p
        return Frame(
            scaleX: axis == .horizontal ? scale : 1,
            scaleY: axis == .vertical ? scale : 1,
            blurRadius: blurRadius * p,
            opacity: 1 - (1 - dimmedOpacity) * p
        )
    }

    /// 屏幕的物理像素宽高比够方（长边 / 短边 < 1.6）才可能是折叠屏：Duo 内外屏都在 1.45 上下，
    /// 普通 iPhone 都在 1.7 以上（SE 1.78，其余 2.1 以上）。只在 iPhone 上用（iPad 本来就方）。
    public static func isFoldableScreen(nativeWidth: Double, nativeHeight: Double) -> Bool {
        let longSide = max(nativeWidth, nativeHeight)
        let shortSide = min(nativeWidth, nativeHeight)
        guard shortSide > 0, longSide.isFinite else { return false }
        return longSide / shortSide < 1.6
    }
}

// MARK: - 按铰链决定什么时候开始（iOS 27.1 起）

extension ScreenChangeTransitionPolicy {
    /// 有铰链读数时（iOS 27.1 起的 iPhone Duo），整屏归位等「铰链停稳在另一端、窗口也已经换了屏」
    /// 之后才开始：系统自己的开合过渡（整窗模糊、拉伸）在铰链停稳前播完，归位接在它后面，不和它
    /// 叠在一起被盖住。窗口可能分几步改尺寸、中间态不铺满整屏，所以铰链这条路不要求画布判定成立，
    /// 只要打开 / 合上期间窗口的尺寸或屏幕变过就算。
    ///
    /// 没有铰链读数（Xcode 27.0 构建、iOS 27.1 以前、拿不到铰链的设备）时退回尺寸判定
    /// （`change(from:to:)`），换屏那一刻立刻开始，和原来一样。
    ///
    /// 纯状态机：调用方把铰链状态变化、窗口画布变化和到点的复查按时间顺序喂进来，照返回的决定办
    /// （开始归位 / 过一会儿再 `tick` / 什么都不做），原因写进诊断日志。
    public struct HingeSequencer: Sendable {
        public enum HingeStatus: String, Sendable, Equatable {
            case closed, partiallyOpen, fullyOpen

            /// 停在一端（合上或完全打开）。
            public var isResting: Bool { self != .partiallyOpen }
        }

        public enum Decision: Equatable, Sendable {
            /// 现在开始整屏归位。
            case fire(axis: Axis, reason: String)
            /// 过这么多秒再调一次 `tick(at:)`。
            case recheck(after: Double, reason: String)
            /// 什么都不做。
            case skip(reason: String)
        }

        /// 铰链停在一端这么久才算停稳（秒）。
        public static let settleDelay: Double = 0.18
        /// 铰链停稳之后最多再等窗口换屏这么久；过了还没换就不做归位。
        public static let windowWait: Double = 1.5
        /// 铰链还停着、窗口先变了：等铰链读数这么久，一直没动就按尺寸判定处理（转屏、分屏拖动都不算换屏）。
        public static let hingeGrace: Double = 0.4

        private struct CanvasMove: Sendable {
            var axis: Axis
            var at: Double
            /// 尺寸判定也认这是一次换屏。
            var isScreenChange: Bool
        }

        /// 收到过铰链读数（而且没有被告知不可用）。
        public private(set) var hasHinge = false
        public private(set) var status: HingeStatus?
        /// 上一次停稳在哪一端。
        private var restingStatus: HingeStatus?
        /// 这次离开那一端的时刻。
        private var leftRestAt: Double?
        /// 到了另一端的时刻（在等它停稳）。
        private var arrivedAt: Double?
        /// 铰链已经停稳、窗口还没换屏时，最多等到这一刻。
        private var awaitingWindowUntil: Double?
        /// 最近一次窗口画布的变化（还没被一次归位用掉）。
        private var canvasMove: CanvasMove?

        public init() {}

        /// 铰链状态变了（只在状态变化时调，角度变化不用）；`nil` 是拿不到铰链读数。
        public mutating func hingeChanged(to newStatus: HingeStatus?, at time: Double) -> Decision {
            guard let newStatus else {
                self = HingeSequencer()
                return .skip(reason: "hinge unavailable, size-based fallback")
            }
            hasHinge = true
            let previous = status
            status = newStatus
            guard let previous else {
                if newStatus.isResting { restingStatus = newStatus }
                return .skip(reason: "initial hinge \(newStatus.rawValue)")
            }
            guard previous != newStatus else { return .skip(reason: "hinge still \(newStatus.rawValue)") }
            if newStatus == .partiallyOpen {
                if leftRestAt == nil { leftRestAt = time }
                arrivedAt = nil
                awaitingWindowUntil = nil
                return .skip(reason: "hinge moving")
            }
            if let restingStatus, restingStatus == newStatus {
                // 打开一半又合回去（或反过来）：没换屏。窗口若中途换过又换回来，净变化也是零。
                clearMotion()
                canvasMove = nil
                return .skip(reason: "hinge back to \(newStatus.rawValue), no fold")
            }
            if leftRestAt == nil { leftRestAt = time }
            arrivedAt = time
            return .recheck(after: Self.settleDelay, reason: "hinge reached \(newStatus.rawValue), waiting to settle")
        }

        /// 窗口的画布变了（尺寸、所在屏幕或尺寸等级）。
        public mutating func canvasChanged(from previous: Canvas, to current: Canvas, at time: Double) -> Decision {
            let sizeChange = ScreenChangeTransitionPolicy.change(from: previous, to: current)
            guard previous.screenID != current.screenID
                || previous.width != current.width
                || previous.height != current.height
                || sizeChange != nil
            else { return .skip(reason: "canvas unchanged") }
            guard hasHinge else {
                if let sizeChange {
                    return .fire(axis: sizeChange.axis, reason: "screen change, no hinge data")
                }
                return .skip(reason: "canvas changed, not a screen change")
            }
            let axis = sizeChange?.axis
                ?? (abs(current.width - previous.width) >= abs(current.height - previous.height) ? .horizontal : .vertical)
            canvasMove = CanvasMove(axis: axis, at: time, isScreenChange: sizeChange != nil)
            if let arrivedAt, status?.isResting == true {
                if awaitingWindowUntil != nil || time - arrivedAt >= Self.settleDelay {
                    return complete(axis: axis, reason: "window moved after hinge settled at \(status?.rawValue ?? "?")")
                }
                return .recheck(
                    after: Self.settleDelay - (time - arrivedAt),
                    reason: "window moved, hinge still settling"
                )
            }
            if status == .partiallyOpen || leftRestAt != nil {
                return .skip(reason: "window moved while hinge is moving, wait for it to settle")
            }
            return .recheck(after: Self.hingeGrace, reason: "window changed with hinge at rest, waiting for hinge")
        }

        /// 到了上一次决定里约好的复查时间。
        public mutating func tick(at time: Double) -> Decision {
            if let arrivedAt, let status, status.isResting {
                let settledFor = time - arrivedAt
                if settledFor < Self.settleDelay - 0.001 {
                    return .recheck(after: Self.settleDelay - settledFor, reason: "hinge still settling")
                }
                if let move = canvasMove, move.at >= (leftRestAt ?? arrivedAt) - Self.hingeGrace {
                    return complete(axis: move.axis, reason: "hinge settled at \(status.rawValue), window already moved")
                }
                guard let until = awaitingWindowUntil else {
                    awaitingWindowUntil = time + Self.windowWait
                    return .recheck(after: Self.windowWait, reason: "hinge settled at \(status.rawValue), waiting for the window")
                }
                if time >= until - 0.001 {
                    restingStatus = status
                    clearMotion()
                    return .skip(reason: "hinge settled at \(status.rawValue) but the window never moved")
                }
                return .skip(reason: "still waiting for the window")
            }
            if let move = canvasMove, leftRestAt == nil, status?.isResting != false {
                let waited = time - move.at
                if waited < Self.hingeGrace - 0.001 {
                    return .recheck(after: Self.hingeGrace - waited, reason: "waiting for hinge")
                }
                canvasMove = nil
                if move.isScreenChange {
                    return .fire(axis: move.axis, reason: "screen change without hinge motion")
                }
                return .skip(reason: "window resized without hinge motion")
            }
            return .skip(reason: "nothing pending")
        }

        private mutating func complete(axis: Axis, reason: String) -> Decision {
            if let status, status.isResting { restingStatus = status }
            clearMotion()
            canvasMove = nil
            return .fire(axis: axis, reason: reason)
        }

        private mutating func clearMotion() {
            leftRestAt = nil
            arrivedAt = nil
            awaitingWindowUntil = nil
        }
    }
}
