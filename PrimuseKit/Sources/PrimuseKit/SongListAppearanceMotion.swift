import Foundation

/// 「方块」外观的网格：一首歌一块，列数只看承载网格的容器宽度。
///
/// 竖屏手机（含最窄的 320 点）固定两列；横屏与 iPad 按最小块宽自适应，
/// 宽屏封顶，免得一块缩成邮票。辅助功能字号下一列，歌名才放得下。
public enum SongTileGridPolicy {
    /// 块与块之间的距离（行列相同）。
    public static let spacing: CGFloat = 12
    /// 网格左右的留白（不含字母索引让出的那一段）。
    public static let horizontalInset: CGFloat = 16
    /// 横屏与 iPad 上一块至少这么宽才再加一列。
    public static let minimumTileWidth: CGFloat = 160
    /// 宽屏的列数上限。
    public static let maximumColumns = 8

    /// - Parameter availableWidth: 扣掉左右留白之后，块真正能排开的宽度。
    public static func columnCount(availableWidth: CGFloat, accessibilitySize: Bool) -> Int {
        guard !accessibilitySize else { return 1 }
        guard availableWidth.isFinite, availableWidth > 0 else { return 2 }
        let fitting = Int(((availableWidth + spacing) / (minimumTileWidth + spacing)).rounded(.down))
        return min(max(fitting, 2), maximumColumns)
    }

    /// 一块的边长。列数由 `columnCount` 给出，这里只做均分。
    public static func tileSide(availableWidth: CGFloat, columns: Int) -> CGFloat {
        let columns = max(columns, 1)
        guard availableWidth.isFinite, availableWidth > 0 else { return 0 }
        let side = (availableWidth - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        return max(side.rounded(.down), 0)
    }

    /// 第几首（从 0 数）落在第几列，网格按行依次填。
    public static func column(forIndex index: Int, columns: Int) -> Int {
        let columns = max(columns, 1)
        let remainder = index % columns
        return remainder < 0 ? remainder + columns : remainder
    }
}

/// 「方块」外观里一块随滚动位置的变化。
///
/// 从底部进入可视区时由小放大、前倾回正、由半透明变实；靠近顶部离开时轻微缩小、
/// 压暗、后仰。同一排的各列按列号错开一点相位，整排滚过时读起来像一道波。
/// 封面在块里做轻微视差。全部只看位置不看速度，所以静止画面就是滚动途中那一帧。
///
/// 坐标都在「可视区」里量：可视区顶部是 0，`viewportHeight` 是滚动区自己的高度
/// （SwiftUI 的滚动区布局框已经让开了导航栏和底栏）。开启「减少动态效果」时一律静止。
public struct SongTileScrollMotion: Equatable, Sendable {
    /// 进入时最小缩放。
    public static let enteringScale: CGFloat = 0.84
    /// 离开时最小缩放。
    public static let leavingScale: CGFloat = 0.92
    /// 进入时最大前倾（度，正值 = 上沿朝向观看者）。再大最下面那排就成了梯形，像画面变形而不是在转。
    public static let enteringTilt: Double = 10
    /// 离开时最大后仰（度）。
    public static let leavingTilt: Double = 8
    /// 进入时最低透明度。
    public static let enteringOpacity: Double = 0.6
    /// 离开时最多压暗多少（亮度减量）。
    public static let leavingDim: Double = 0.24
    /// 3D 旋转的透视强度，视图层传给 `rotation3DEffect` 的 `perspective`。
    public static let perspective: CGFloat = 0.5
    /// 封面视差的幅度，按块高的比例。
    public static let parallaxFraction: CGFloat = 0.05
    /// 封面比块大多少，好让视差移动时四边不露底。
    public static let artworkOverscan: CGFloat = 1.12
    /// 一整排里最后一列比第一列晚多少（按块高的比例）。
    public static let rowPhaseSpread: CGFloat = 0.3

    public let scale: CGFloat
    /// 绕 X 轴的角度（度），正值上沿朝向观看者。
    public let tilt: Double
    public let opacity: Double
    /// 亮度减量，0 不变。
    public let dim: Double
    /// 封面在块里的竖向位移（点）。
    public let parallax: CGFloat

    public static let identity = SongTileScrollMotion(scale: 1, tilt: 0, opacity: 1, dim: 0, parallax: 0)

    private init(scale: CGFloat, tilt: Double, opacity: Double, dim: Double, parallax: CGFloat) {
        self.scale = scale
        self.tilt = tilt
        self.opacity = opacity
        self.dim = dim
        self.parallax = parallax
    }

    /// - Parameters:
    ///   - tileMinY: 块上沿到可视区顶部的距离（在可视区下方为正）。
    ///   - tileHeight: 块高。
    ///   - viewportHeight: 可视区高度。
    ///   - column: 这块在第几列（从 0 数，从行首数起）。
    ///   - columnCount: 一排几列。
    public init(
        tileMinY: CGFloat,
        tileHeight: CGFloat,
        viewportHeight: CGFloat,
        column: Int,
        columnCount: Int,
        reduceMotion: Bool
    ) {
        guard !reduceMotion, tileMinY.isFinite, tileHeight.isFinite, viewportHeight.isFinite,
              tileHeight > 0, viewportHeight > 0 else {
            self = .identity
            return
        }
        let columns = max(columnCount, 1)
        let column = min(max(column, 0), columns - 1)
        let lag = columns > 1
            ? tileHeight * Self.rowPhaseSpread * CGFloat(column) / CGFloat(columns - 1)
            : 0
        // 后几列当作比实际低一点：进入晚一点，离开也晚一点。
        let top = tileMinY + lag

        // 进入：块从底边升起的高度，升起一个块高多一点时完全复原。
        let enterBand = min(tileHeight * 1.15, viewportHeight * 0.55)
        let enter = SongListMotionCurve.smooth((viewportHeight - top) / enterBand)
        // 离开：上沿滑进顶栏下面才开始（停在最上面的第一排保持原样），滑进大半块时到底。
        let exitBand = min(tileHeight * 0.85, viewportHeight * 0.45)
        let exit = SongListMotionCurve.smooth(-top / exitBand)

        scale = (1 - (1 - Self.enteringScale) * (1 - enter)) * (1 - (1 - Self.leavingScale) * exit)
        tilt = Self.enteringTilt * Double(1 - enter) - Self.leavingTilt * Double(exit)
        opacity = Self.enteringOpacity + (1 - Self.enteringOpacity) * Double(enter)
        dim = Self.leavingDim * Double(exit)
        parallax = Self.parallax(
            tileMidY: tileMinY + tileHeight / 2,
            tileHeight: tileHeight,
            viewportHeight: viewportHeight
        )
    }

    /// 封面视差：块在可视区下半部时封面偏上，滚到上半部时偏下，比块本身走得慢。
    /// 幅度不超过 `artworkOverscan` 留出的余量。
    public static func parallax(tileMidY: CGFloat, tileHeight: CGFloat, viewportHeight: CGFloat) -> CGFloat {
        guard tileMidY.isFinite, tileHeight.isFinite, viewportHeight.isFinite,
              tileHeight > 0, viewportHeight > 0 else { return 0 }
        let reach = viewportHeight / 2 + tileHeight / 2
        let position = SongListMotionCurve.clamp((tileMidY - viewportHeight / 2) / reach, -1, 1)
        return -position * tileHeight * parallaxFraction
    }

    /// 带透视的 3D 旋转后，块最宽的那条边相对原尺寸的比例（近似）。
    /// 用来确认缩放与倾斜叠在一起也不会画出自己的格子。
    public var projectedExtent: CGFloat {
        let lift = CGFloat(sin(abs(tilt) * .pi / 180)) / 2 * Self.perspective
        guard lift < 1 else { return .infinity }
        return scale / (1 - lift)
    }
}

/// 「聚焦」外观里一张卡随滚动位置的变化。
///
/// 滚到可视区中部的那一两行是完整大小，封面带柔和阴影；离中心越远越小、越淡，
/// 封面绕 Y 轴转开一点。靠近上下边缘的几行往中心收拢：每行按自己缩小后的尺寸
/// 重新排紧，相邻两张卡之间至少留 `minimumGap`，所以收拢不会叠到邻居身上。
///
/// 上下对称：同样离中心远的两行，缩放、透明度、转角相同，位移大小相同方向相反。
public struct SongFocusScrollMotion: Equatable, Sendable {
    /// 最远处的缩放。
    public static let minimumScale: CGFloat = 0.9
    /// 最远处的透明度。
    public static let minimumOpacity: Double = 0.62
    /// 最远处封面绕 Y 轴的转角（度）。再大边缘几行的封面就歪成平行四边形。
    public static let maximumCoverTurn: Double = 16
    /// 收拢后相邻两张卡至少还隔着的距离（点）。
    public static let minimumGap: CGFloat = 3
    /// 中心多大一段保持原样，按行距算。
    static let coreRows: CGFloat = 0.6

    public let scale: CGFloat
    public let opacity: Double
    /// 封面绕 Y 轴的转角（度），始终 ≥ 0，方向由视图按书写方向决定。
    public let coverTurn: Double
    /// 朝中心收拢的竖向位移（点）。上半部为正（往下），下半部为负（往上）。
    public let offset: CGFloat
    /// 居中程度，1 在正中，用来淡入封面阴影。
    public let emphasis: Double

    public static let identity = SongFocusScrollMotion(scale: 1, opacity: 1, coverTurn: 0, offset: 0, emphasis: 1)

    private init(scale: CGFloat, opacity: Double, coverTurn: Double, offset: CGFloat, emphasis: Double) {
        self.scale = scale
        self.opacity = opacity
        self.coverTurn = coverTurn
        self.offset = offset
        self.emphasis = emphasis
    }

    /// - Parameters:
    ///   - rowMidY: 卡片中心到可视区顶部的距离。
    ///   - rowPitch: 相邻两行中心的距离（行高加上下留白）。
    ///   - cardHeight: 卡片本身的高度。
    ///   - viewportHeight: 可视区高度。
    public init(
        rowMidY: CGFloat,
        rowPitch: CGFloat,
        cardHeight: CGFloat,
        viewportHeight: CGFloat,
        reduceMotion: Bool
    ) {
        guard !reduceMotion, rowMidY.isFinite, rowPitch.isFinite, cardHeight.isFinite,
              viewportHeight.isFinite, rowPitch > 0, cardHeight > 0, viewportHeight > 0 else {
            self = .identity
            return
        }
        let card = min(cardHeight, rowPitch)
        let half = viewportHeight / 2
        let fromCenter = rowMidY - half
        let core = min(0.8, rowPitch * Self.coreRows / half)
        let width = half * (1 - core)
        let progress = (abs(fromCenter) / half - core) / (1 - core)
        let distance = SongListMotionCurve.smooth(progress)

        scale = 1 - (1 - Self.minimumScale) * distance
        opacity = 1 - (1 - Self.minimumOpacity) * Double(distance)
        coverTurn = Self.maximumCoverTurn * Double(distance)
        emphasis = 1 - Double(SongListMotionCurve.smooth(abs(fromCenter) / (half * core + rowPitch * 0.6)))

        // 每一小段都按「缩小后的卡高 + 收窄的间隙」重新排：位移就是这些节省下来的
        // 距离从中心累加到这一行。累加用平滑曲线的定积分，闭式可算。
        let gap = rowPitch - card
        let saved = (1 - Self.minimumScale) * card + gap - min(gap, Self.minimumGap)
        // 行距相对过渡段太大时（横屏、超大字号）曲线在一行之内走完，按行累加会估过头，
        // 这时收拢按比例减弱，直到不再收拢。
        let rate = saved / rowPitch * SongListMotionCurve.clamp(width / (rowPitch * 2.5), 0, 1)
        let clamped = SongListMotionCurve.clamp(progress, 0, 1)
        let cube = clamped * clamped * clamped
        let integral = width * (cube - cube * clamped / 2) + max(0, abs(fromCenter) - half)
        let shift = rate * integral
        offset = fromCenter > 0 ? -shift : shift
    }
}

enum SongListMotionCurve {
    static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        guard value.isFinite else { return value > 0 ? upper : lower }
        return min(max(value, lower), upper)
    }

    /// 0…1 之间的平滑过渡（smoothstep），两端斜率为 0，不会在边界上突然起步。
    static func smooth(_ value: CGFloat) -> CGFloat {
        let t = clamp(value, 0, 1)
        return t * t * (3 - 2 * t)
    }
}
