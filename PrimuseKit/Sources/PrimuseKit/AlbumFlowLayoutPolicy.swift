import Foundation

/// 全屏「封面流」(#191)的唱片架：几何、浏览拖动与点按判定。
///
/// 选中的那张（没在浏览时就是正在播的这首）从架子里抽出来，正对着人、抬高一截；播放队列里刚放过的
/// 竖插在左边、接下来的竖插在右边，只露出窄窄的书脊，越远越小、越暗。左右拨动只是浏览：拖动时架子
/// 合拢、书脊跟着手走，路过中间的那张只稍稍抽出一点又插回去；停住时架子让开，停住的那张整个抽出来。
/// 舞台画面、全屏页的拖动与点按判定用同一份几何，免得画的和点的对不上。
public enum AlbumFlowLayoutPolicy {
    public struct Layout: Equatable, Sendable {
        /// 抽出来的那张的边长与左上角（画布坐标）。
        public var centerSide: Double
        public var centerOriginX: Double
        public var centerOriginY: Double
        /// 插在架子里的唱片多高（离选中那张最近的一张；再往外逐张缩小）。
        public var rackSide: Double
        /// 最近那张书脊露出多宽。
        public var spineWidth: Double
        /// 架子合拢时相邻两张书脊中心的间距。
        public var spinePitch: Double
        /// 架子为抽出的那张让开位置时，第一张书脊的中心离中间多远。
        public var firstSpineOffset: Double
        /// 抽出的那张底边比架子台面高出多少。
        public var liftHeight: Double
        /// 台面以下给架子底板留多高，歌词排在它下面。
        public var shelfDepth: Double
        /// 歌名一块的上沿与高度：在抽出那张的上面。
        public var titleOriginY: Double
        public var titleHeight: Double
        /// 歌词一块的上沿与高度：在架子底板下面。没给歌词留位置时高度为 0。
        public var lyricOriginY: Double
        public var lyricHeight: Double

        public var centerMidX: Double { centerOriginX + centerSide / 2 }
        public var centerMidY: Double { centerOriginY + centerSide / 2 }
        /// 唱片架的台面：书脊都立在这条线上。
        public var baseline: Double { centerOriginY + centerSide + liftHeight }
        /// 每张都按抽出来的边长画好再缩放，书脊在这张牌面上占多宽（比例）。
        public var spineFaceShare: Double { spineWidth / max(rackSide, 1) }

        /// 离浏览中心 `position` 格的那一张画在哪、多大、抽出多少；负数在左，拖动途中是小数。
        ///
        /// `settle` 是架子张开的程度：1 是停住（中间那张整个抽出来、两侧让开），0 是拖动中（架子合拢、
        /// 路过中间的那张只抽出 `passingPull`）。两头之间连续变化，带动画时一帧帧插值。
        public func placement(at position: Double, settle: Double = 1) -> Placement {
            let openness = min(max(settle, 0), 1)
            let distance = abs(position)
            let direction: Double = position < 0 ? -1 : 1
            let opening = spinePitch + (firstSpineOffset - spinePitch) * openness
            let reach = distance <= 1
                ? distance * opening
                : opening + AlbumFlowLayoutPolicy.spineRun(distance - 1) * spinePitch
            let closeness = distance >= 1 ? 0 : 1 - AlbumFlowLayoutPolicy.smoothstep(distance)
            let passing = AlbumFlowLayoutPolicy.passingPull
            let pull = closeness * (passing + (1 - passing) * openness)
            let rackScale = rackSide / max(centerSide, 1) * AlbumFlowLayoutPolicy.depthScale(distance)
            // 刚抽出一点时只往上抬，过了这一段才放大、转成正面。
            let grow = AlbumFlowLayoutPolicy.smoothstep((pull - 0.25) / 0.75)
            let steps = max(distance - 1, 0)
            let shade = min(
                AlbumFlowLayoutPolicy.rackShade + AlbumFlowLayoutPolicy.depthShade * steps,
                AlbumFlowLayoutPolicy.maximumShade
            ) * (1 - pull)
            let fade = max(distance - AlbumFlowLayoutPolicy.fadeStart, 0) * AlbumFlowLayoutPolicy.fadeRate
            return Placement(
                midX: centerMidX + direction * reach,
                bottomY: baseline - liftHeight * sin(pull * .pi / 2),
                scale: rackScale + (1 - rackScale) * grow,
                pull: pull,
                shade: shade,
                opacity: min(max(1 - fade, 0), 1)
            )
        }

        /// 点在不在抽出来的那张上。`tolerance` 往外放宽一圈，手指点偏一点也算。
        public func centerContains(x: Double, y: Double, tolerance: Double = 0) -> Bool {
            x >= centerOriginX - tolerance
                && x <= centerOriginX + centerSide + tolerance
                && y >= centerOriginY - tolerance
                && y <= centerOriginY + centerSide + tolerance
        }

        /// 点中了哪一张：返回它离正在播的这张几格（0 是正在播的这张，负数在左）；点在空白处为 nil。
        /// `browsePosition` 是此刻浏览到哪（停住时是整数），`before` / `after` 是两侧实际画了几张。
        /// 先认抽出来的那张；书脊按它所在的那一格认（一格含两张书脊之间的缝，窄窄的书脊也点得中）。
        public func offset(
            atX x: Double,
            y: Double,
            browsePosition: Double,
            before: Int,
            after: Int,
            tolerance: Double = 0
        ) -> Int? {
            let lower = -max(before, 0)
            let upper = max(after, 0)
            let selected = min(max(Int(browsePosition.rounded()), lower), upper)
            if centerContains(x: x, y: y, tolerance: tolerance) { return selected }
            guard y >= baseline - rackSide - tolerance, y <= baseline + tolerance else { return nil }
            var best: (offset: Int, gap: Double)?
            for offset in lower...upper where offset != selected {
                let distance = Double(offset) - browsePosition
                let card = self.placement(at: distance)
                guard card.opacity > 0.05 else { continue }
                let halfCell = spinePitch * AlbumFlowLayoutPolicy.depthScale(abs(distance)) / 2 + tolerance
                let gap = abs(x - card.midX)
                guard gap <= halfCell, gap < (best?.gap ?? .infinity) else { continue }
                best = (offset, gap)
            }
            return best?.offset
        }

        /// 手指横向拖了 `translation` 点之后浏览到哪：向左拖往右边（接下来的）走。拖的时候架子合拢，
        /// 一张书脊的间距算一格，书脊跟着手走；拖过两头只能再拉出一点（像橡皮筋）。
        /// `anchor` 是起手时浏览到哪，`before` / `after` 是两侧有几张。
        public func browsePosition(from anchor: Double, translation: Double, before: Int, after: Int) -> Double {
            let raw = anchor - translation / max(spinePitch, 1)
            let lower = -Double(max(before, 0))
            let upper = Double(max(after, 0))
            if raw > upper {
                return upper + AlbumFlowLayoutPolicy.rubberBand(raw - upper, limit: AlbumFlowLayoutPolicy.endStretch)
            }
            if raw < lower {
                return lower - AlbumFlowLayoutPolicy.rubberBand(lower - raw, limit: AlbumFlowLayoutPolicy.endStretch)
            }
            return raw
        }
    }

    /// 一张唱片在连续位置上的样子。整张按抽出来的边长画，`scale` 是缩放到多大。
    public struct Placement: Equatable, Sendable {
        public var midX: Double
        /// 底边的纵坐标：插在架子里时立在台面上，抽出来时抬高一截。
        public var bottomY: Double
        public var scale: Double
        /// 抽出多少：0 只露书脊，1 整个抽出来、正对着人。
        public var pull: Double
        /// 书脊压暗多少：越远越暗，抽出来就不压。
        public var shade: Double
        /// 架子最外头几张渐渐淡出，不在画布上突然断掉。
        public var opacity: Double

        /// 正面露出多宽：0 只有书脊那一条，1 整面。从中间往两边展开，不是绕竖轴转过来。
        public var faceReveal: Double { AlbumFlowLayoutPolicy.smoothstep((pull - 0.3) / 0.7) }
        public var faceOpacity: Double { AlbumFlowLayoutPolicy.smoothstep((pull - 0.2) / 0.3) }
        public var spineOpacity: Double { 1 - AlbumFlowLayoutPolicy.smoothstep((pull - 0.4) / 0.35) }
        /// 正在播的那张叠的成品卡片（动态封面、玻璃描边、专辑色投影）：整个抽出来时才显出来。
        public var heroOpacity: Double { AlbumFlowLayoutPolicy.smoothstep((pull - 0.75) / 0.25) }
    }

    /// 两侧每边最多几张：同屏连抽出的那张不超过 13 张。
    public static let maximumNeighborsPerSide = 6
    /// 插在架子里的唱片比抽出来的那张矮多少。
    public static let rackScale = 0.74
    /// 书脊宽占抽出那张边长的比例。
    public static let spineShare = 0.12
    /// 两张书脊之间的缝占书脊宽的比例。横着的画布宽，缝放宽一些，架子往两边多铺一截。
    static let spineGapShare = 0.16
    static let landscapeSpineGapShare = 0.3
    /// 架子张开时抽出的那张两边各让出多宽（占边长）。
    static let clearanceShare = 0.06
    /// 抽出的那张抬高多少、台面下面留多高（都占边长）。
    public static let liftShare = 0.1
    public static let shelfShare = 0.06
    /// 拖动途中路过中间的那张最多抽出多少。
    public static let passingPull = 0.3
    /// 往外每多一张书脊缩小多少、压暗多少；缩到第几张为止。
    static let depthShrink = 0.035
    static let maximumDepthSteps = 6
    static let rackShade = 0.06
    static let depthShade = 0.07
    static let maximumShade = 0.5
    /// 第几张起渐渐淡出、每张淡多少。
    static let fadeStart = 4.0
    static let fadeRate = 0.3
    /// 中间封面最小边长：画布实在太矮时以它为准，不再缩。
    public static let minimumCenterSide = 96.0
    /// 拖过两头最多再拉出几格。
    static let endStretch = 0.35

    /// 离中间 `distance` 格的书脊缩到多大（最近的一张为 1）。
    static func depthScale(_ distance: Double) -> Double {
        1 - depthShrink * min(max(distance - 1, 0), Double(maximumDepthSteps))
    }

    /// 从最近那张书脊往外数 `steps` 格，中心挪了几个间距：书脊越往外越小，间距跟着缩。
    static func spineRun(_ steps: Double) -> Double {
        let shrinking = min(max(steps, 0), Double(maximumDepthSteps))
        let beyond = max(steps - Double(maximumDepthSteps), 0)
        return shrinking - depthShrink * shrinking * shrinking / 2
            + beyond * (1 - depthShrink * Double(maximumDepthSteps))
    }

    static func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * (3 - 2 * x)
    }

    /// 拉橡皮筋：起初跟手，越往外越沉，永远到不了 `limit`。
    static func rubberBand(_ distance: Double, limit: Double) -> Double {
        guard distance > 0, limit > 0 else { return 0 }
        return distance / (distance / limit + 1)
    }

    /// - Parameters:
    ///   - topInset / bottomInset: 舞台上沿要让开的圆钮排、下沿要让开的控件。
    ///   - horizontalInset: 左右安全区。书脊可以伸进去，抽出的那张与歌名不进。
    ///   - titleHeight: 歌名一块要的高度，由视图层按字号给。
    ///   - lyricHeight / lyricSpacing: 架子下面给歌词留多高、离架子多远；0 表示不留。
    public static func layout(
        canvasWidth: Double,
        canvasHeight: Double,
        topInset: Double,
        bottomInset: Double,
        horizontalInset: Double,
        titleHeight: Double,
        titleSpacing: Double,
        lyricHeight: Double = 0,
        lyricSpacing: Double = 0
    ) -> Layout {
        let width = max(canvasWidth, 1)
        let height = max(canvasHeight, 1)
        let isLandscape = width > height
        let contentTop = max(topInset, 0) + max(titleHeight, 0) + max(titleSpacing, 0)
        let contentBottom = height - max(bottomInset, 0)
        let lyricBlock = lyricHeight > 0 ? lyricHeight + max(lyricSpacing, 0) : 0
        // 抽出的那张、它抬起的那一截、架子底板，再加歌词，要放进歌名与控件之间。
        let availableHeight = max(contentBottom - contentTop, 0)
        let verticalShare = 1 + liftShare + shelfShare
        let widthCap = (width - 2 * max(horizontalInset, 0)) * (isLandscape ? 0.36 : 0.66)
        let side = max(min((availableHeight - lyricBlock) / verticalShare, widthCap), minimumCenterSide)
        let originX = (width - side) / 2
        // 唱片、架子与歌词这一组在可用高度里居中；放不下时贴着歌名。
        let groupHeight = side * verticalShare + lyricBlock
        let originY = contentTop + max((availableHeight - groupHeight) / 2, 0)
        let spineWidth = side * spineShare
        let baseline = originY + side * (1 + liftShare)

        return Layout(
            centerSide: side,
            centerOriginX: originX,
            centerOriginY: originY,
            rackSide: side * rackScale,
            spineWidth: spineWidth,
            spinePitch: spineWidth * (1 + (isLandscape ? landscapeSpineGapShare : spineGapShare)),
            firstSpineOffset: side / 2 + side * clearanceShare + spineWidth / 2,
            liftHeight: side * liftShare,
            shelfDepth: side * shelfShare,
            titleOriginY: max(originY - max(titleSpacing, 0) - max(titleHeight, 0), max(topInset, 0)),
            titleHeight: max(titleHeight, 0),
            lyricOriginY: baseline + side * shelfShare + (lyricHeight > 0 ? max(lyricSpacing, 0) : 0),
            lyricHeight: max(lyricHeight, 0)
        )
    }
}

/// 封面流的浏览：左右拨动只是看看，停住的那张抽出来，选它才换歌；一阵子没动静就回到正在播的那张。
/// 三端的全屏页（手指、触控板与方向键、遥控器）共用这几条规则，界面层只管把输入换成格数。
public enum AlbumFlowBrowsePolicy {
    /// 停在别的唱片上多久没有操作，就自己回到正在播的那张。
    public static let idleReturnDelay = 3.0
    /// 停住时「轻点播放」那行提示露多久。
    public static let hintDuration = 2.0
    /// 「已排到下一首」露多久。
    public static let confirmationDuration = 1.6
    /// 甩一下最多再多走几张：甩得再猛也不一下子到头，看得清路过了什么。
    public static let maximumFlingSteps = 4.0

    /// 停在哪一张：四舍五入到整数格，不出两头。拖动途中它一变就给一下轻触感。
    public static func detent(at position: Double, before: Int, after: Int) -> Int {
        guard position.isFinite else { return 0 }
        return min(max(Int(position.rounded()), -max(before, 0)), max(after, 0))
    }

    /// 松手后吸附到哪一张：按松手时的势头估出落点（`predictedPosition`，同样按格算），取最近的一张。
    public static func releaseTarget(position: Double, predictedPosition: Double, before: Int, after: Int) -> Int {
        let momentum = predictedPosition.isFinite ? predictedPosition - position : 0
        let limited = position + min(max(momentum, -maximumFlingSteps), maximumFlingSteps)
        return detent(at: limited, before: before, after: after)
    }

    /// 方向键、遥控器左右、鼠标滚轮：从停住的那张往一边挪 `delta` 张，到头不动。
    public static func step(from index: Int, by delta: Int, before: Int, after: Int) -> Int {
        min(max(index + delta, -max(before, 0)), max(after, 0))
    }

    /// 拖出多远架子就整个合拢（格）。
    public static let collapseDistance = 0.5

    /// 拖动途中架子张开多少：起手时是多少（通常整个抽出来），手一动就跟着插回去，拖出半格合拢。
    public static func dragSettle(from start: Double, travelled: Double) -> Double {
        let progress = travelled.isFinite ? abs(travelled) / collapseDistance : 1
        return min(max(start, 0), 1) * (1 - AlbumFlowLayoutPolicy.smoothstep(progress))
    }

    /// 该不该自己回到正在播的那张：停在别的唱片上、手没在拖、离上一次操作满 `idleReturnDelay` 秒。
    public static func shouldReturnToPlaying(browseIndex: Int, isInteracting: Bool, idle: Double) -> Bool {
        browseIndex != 0 && !isInteracting && idle >= idleReturnDelay
    }

    /// 一次挪动（回位、吸附、点中书脊）分几段走，每段几秒。
    public struct Motion: Equatable, Sendable {
        /// 先把抽出的那张插回去、架子合拢。
        public var collapse: Double
        /// 整排滑到目标。
        public var travel: Double
        /// 停住的那张抽出来。
        public var expand: Double

        public var isInstant: Bool { collapse == 0 && travel == 0 && expand == 0 }
    }

    /// 只差一张时位置与抽出一起动；差得远时分三段：先插回、合拢，整排滑过去，再把停住的那张抽出来 ——
    /// 一起动的话路过中间的几张会一张张整个抽出来闪一下。减弱动态效果时直接到位。
    public static func motion(distance: Double, reduceMotion: Bool) -> Motion {
        guard !reduceMotion, distance.isFinite, distance > 0.001 else {
            return Motion(collapse: 0, travel: 0, expand: 0)
        }
        guard distance > 1.5 else { return Motion(collapse: 0, travel: 0.42, expand: 0) }
        return Motion(collapse: 0.16, travel: min(0.3 + 0.06 * distance, 0.66), expand: 0.34)
    }

    /// 上拉排到下一首：抽出的那张跟着手往上抬多高（点）。往下拉不动；过了要拉够的那一截越拉越沉。
    public static func queueLiftOffset(translation: Double, centerSide: Double) -> Double {
        let raised = max(-translation, 0)
        let threshold = queueLiftThreshold(centerSide: centerSide)
        guard raised > threshold else { return raised }
        return threshold + AlbumFlowLayoutPolicy.rubberBand(raised - threshold, limit: max(centerSide, 1) * 0.12)
    }

    /// 松手时排不排到下一首：拉够一截，或拉了一点但往上甩得够猛。
    public static func queueLiftCommits(translation: Double, predictedTranslation: Double, centerSide: Double) -> Bool {
        let threshold = queueLiftThreshold(centerSide: centerSide)
        let raised = -translation
        let predicted = predictedTranslation.isFinite ? -predictedTranslation : raised
        return raised >= threshold || (raised >= threshold * 0.35 && predicted >= threshold * 2.2)
    }

    /// 要往上拉多少才算：抽出那张边长的两成多，至少 44 点。
    public static func queueLiftThreshold(centerSide: Double) -> Double {
        max(centerSide * 0.22, 44)
    }
}
