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

    /// 从换屏那一刻回到原样的时长（秒）。
    public static let duration: Double = 0.45
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
