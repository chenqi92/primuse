import Foundation

/// 全屏「封面流」(#191)的几何、拖动与点按判定。
///
/// 正在播的这首居中、正对着人；播放队列里刚放过的斜着排在左边，接下来要放的排在右边，
/// 像一排立着的唱片，下面是倒影，再下面是歌词。舞台画面、全屏页的拖动与点按判定用同一份几何，
/// 免得画的和点的对不上。
public enum AlbumFlowLayoutPolicy {
    public struct Layout: Equatable, Sendable {
        /// 中间封面的边长与左上角（画布坐标）。
        public var centerSide: Double
        public var centerOriginX: Double
        public var centerOriginY: Double
        /// 两侧封面的边长。
        public var neighborSide: Double
        /// 第一张邻居的中心离中间封面中心多远。
        public var firstNeighborOffset: Double
        /// 往外每多一张，中心再挪多远。斜着的封面彼此叠着，所以比边长小得多。
        public var neighborSpacing: Double
        /// 两侧每边画几张：画布放得下的上限，实际还要看有几张可画。
        public var neighborsPerSide: Int
        /// 两侧封面绕竖轴转的角度（度），朝向中间。
        public var tiltDegrees: Double
        /// 倒影露出的高度占封面边长的比例。
        public var reflectionFraction: Double
        /// 歌名一块的上沿与高度：在封面上面。
        public var titleOriginY: Double
        public var titleHeight: Double
        /// 歌词一块的上沿与高度：在倒影露出的那一截下面。没给歌词留位置时高度为 0。
        public var lyricOriginY: Double
        public var lyricHeight: Double

        public var centerMidX: Double { centerOriginX + centerSide / 2 }
        public var centerMidY: Double { centerOriginY + centerSide / 2 }
        /// 所有封面立着的那条底线（台面上沿）。
        public var baseline: Double { centerOriginY + centerSide }

        /// 第 `offset` 张邻居（负数在左、正数在右，±1 紧挨着中间）的中心横坐标。
        public func neighborMidX(offset: Int) -> Double {
            placement(at: Double(offset)).midX
        }

        /// 离中间 `position` 格的那一张画在哪、多大、斜多少；负数在左，拖动途中是小数。
        /// 0 是中间那张的大小、正对着人；到 ±1 缩成两侧的大小、转到两侧的角度；再往外只是一张张叠着往外排。
        public func placement(at position: Double) -> Placement {
            let distance = abs(position)
            let direction: Double = position < 0 ? -1 : 1
            let inner = min(distance, 1)
            let reach = distance <= 1
                ? inner * firstNeighborOffset
                : firstNeighborOffset + (distance - 1) * neighborSpacing
            return Placement(
                midX: centerMidX + direction * reach,
                side: centerSide + (neighborSide - centerSide) * inner,
                tiltDegrees: inner == 0 ? 0 : -direction * tiltDegrees * inner,
                opacity: distance <= 1 ? 1 : max(0, 1 - (distance - 1) * 0.08)
            )
        }

        /// 点在不在中间这张封面上。`tolerance` 往外放宽一圈，手指点偏一点也算。
        public func centerContains(x: Double, y: Double, tolerance: Double = 0) -> Bool {
            x >= centerOriginX - tolerance
                && x <= centerOriginX + centerSide + tolerance
                && y >= centerOriginY - tolerance
                && y <= centerOriginY + centerSide + tolerance
        }

        /// 点中了哪一张：0 是中间那张，负数在左、正数在右；`before` / `after` 是两侧实际画了几张。
        /// 两侧的斜着叠在一起、靠里的压在上面，所以先认靠里的。点在倒影、空白处为 nil。
        public func offset(atX x: Double, y: Double, before: Int, after: Int, tolerance: Double = 0) -> Int? {
            if centerContains(x: x, y: y, tolerance: tolerance) { return 0 }
            guard y >= baseline - neighborSide - tolerance, y <= baseline + tolerance else { return nil }
            let isRight = x > centerMidX
            let count = isRight ? after : before
            guard count > 0 else { return nil }
            let halfWidth = neighborSide * AlbumFlowLayoutPolicy.tiltedHalfWidthShare + tolerance
            for distance in 1...count {
                let offset = isRight ? distance : -distance
                if abs(x - neighborMidX(offset: offset)) <= halfWidth { return offset }
            }
            return nil
        }

        /// 手指横向拖了 `translation` 点，整排挪了几格。向左拖为正：右边那张往中间走。
        /// 拖满第一张邻居到中间的距离算一格，再往外越拖越沉；那一边没有封面时只能拉出一点（像橡皮筋）。
        public func dragShift(translation: Double, hasBefore: Bool, hasAfter: Bool) -> Double {
            let raw = -translation / max(firstNeighborOffset, 1)
            let hasTarget = raw > 0 ? hasAfter : hasBefore
            let magnitude = abs(raw)
            let limited: Double
            if !hasTarget {
                limited = AlbumFlowLayoutPolicy.rubberBand(magnitude, limit: AlbumFlowLayoutPolicy.emptySideStretch)
            } else if magnitude <= 1 {
                limited = magnitude
            } else {
                limited = 1 + AlbumFlowLayoutPolicy.rubberBand(magnitude - 1, limit: AlbumFlowLayoutPolicy.overscrollStretch)
            }
            return raw < 0 ? -limited : limited
        }
    }

    /// 一张封面在连续位置上的样子。
    public struct Placement: Equatable, Sendable {
        public var midX: Double
        public var side: Double
        /// 绕竖轴转多少度：左边的为正、右边的为负，朝向中间。
        public var tiltDegrees: Double
        public var opacity: Double
    }

    /// 两侧每边最多画几张。再多也只是挤在屏幕边上的细条。
    public static let maximumNeighborsPerSide = 6
    public static let tiltDegrees = 58.0
    public static let reflectionFraction = 0.34
    /// 倒影越往下越淡，只要求上面这一截露在控件之上，其余淡进控件底下。
    public static let visibleReflectionShare = 0.4
    public static let neighborScale = 0.8
    /// 中间封面最小边长：画布实在太矮时以它为准，不再缩。
    public static let minimumCenterSide = 96.0
    /// 斜过去的封面在屏幕上大约露出多宽（占边长的一半的比例）：cos 58° 再加一点透视放大的近边。
    static let tiltedHalfWidthShare = 0.3
    /// 没有封面的那一边最多拉出几格；有封面时拖过一整格后最多再多拉几格。
    static let emptySideStretch = 0.3
    static let overscrollStretch = 0.25
    /// 松手时拖过几格就换歌；没拖够但甩出去的势头能过这么多格也换。
    public static let commitShift = 0.3
    public static let flingShift = 0.6

    /// 松手后往哪边换：1 下一首、-1 上一首、0 弹回原处。
    /// `predictedShift` 是按手指松开时的速度估出来的落点（同样按格算），甩一下也能换。
    public static func releaseStep(shift: Double, predictedShift: Double) -> Int {
        if abs(shift) >= commitShift { return shift > 0 ? 1 : -1 }
        let sameDirection = shift == 0 || (predictedShift > 0) == (shift > 0)
        if abs(predictedShift) >= flingShift, sameDirection { return predictedShift > 0 ? 1 : -1 }
        return 0
    }

    /// 拉橡皮筋：起初跟手，越往外越沉，永远到不了 `limit`。
    static func rubberBand(_ distance: Double, limit: Double) -> Double {
        guard distance > 0, limit > 0 else { return 0 }
        return distance / (distance / limit + 1)
    }

    /// - Parameters:
    ///   - topInset / bottomInset: 舞台上沿要让开的圆钮排、下沿要让开的控件。
    ///   - horizontalInset: 左右安全区。邻居可以伸进去一点，中间封面与歌名不进。
    ///   - titleHeight: 歌名一块要的高度，由视图层按字号给。
    ///   - lyricHeight / lyricSpacing: 倒影下面给歌词留多高、离倒影多远；0 表示不留。
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
        // 封面加倒影上面那一截、再加歌词，要放进歌名与控件之间。
        let availableHeight = max(contentBottom - contentTop, 0)
        let visibleReflection = reflectionFraction * visibleReflectionShare
        let widthCap = (width - 2 * max(horizontalInset, 0)) * (isLandscape ? 0.36 : 0.66)
        let side = max(
            min((availableHeight - lyricBlock) / (1 + visibleReflection), widthCap),
            minimumCenterSide
        )
        let originX = (width - side) / 2
        // 封面、倒影与歌词这一组在可用高度里居中；放不下时贴着歌名。
        let groupHeight = side * (1 + visibleReflection) + lyricBlock
        let originY = contentTop + max((availableHeight - groupHeight) / 2, 0)

        let neighborSide = side * neighborScale
        let firstOffset = side / 2 + neighborSide * 0.42
        let spacing = neighborSide * 0.34
        let halfWidth = width / 2
        // 最外一张的中心可以落到画布边外半张斜封面的宽度，边上不留空。
        let reach = halfWidth + neighborSide * 0.25 - firstOffset
        let perSide = reach < 0 ? 0 : min(Int(reach / spacing) + 1, maximumNeighborsPerSide)

        return Layout(
            centerSide: side,
            centerOriginX: originX,
            centerOriginY: originY,
            neighborSide: neighborSide,
            firstNeighborOffset: firstOffset,
            neighborSpacing: spacing,
            neighborsPerSide: perSide,
            tiltDegrees: tiltDegrees,
            reflectionFraction: reflectionFraction,
            titleOriginY: max(originY - max(titleSpacing, 0) - max(titleHeight, 0), max(topInset, 0)),
            titleHeight: max(titleHeight, 0),
            lyricOriginY: originY + side * (1 + visibleReflection) + (lyricHeight > 0 ? max(lyricSpacing, 0) : 0),
            lyricHeight: max(lyricHeight, 0)
        )
    }
}

/// 电视「封面流」两侧的封面换成曲库里别的专辑:一整张专辑连着放时,两侧每张都是同一张封面,
/// 切歌时整排滑过去也看不出动。只换卡片上画的封面,卡片仍对应原来的队列位置,遥控器左右键
/// 照旧是上一首、下一首。
///
/// 从中间往两边数,一张卡和它靠中间那张(中间这首也算)是同一张专辑时换掉;换成另一张专辑的
/// 第一张保留原封面,让人看得到接下来是哪张专辑。换上的封面按卡片在队列里的位置取,同一张卡
/// 滑来滑去不会换图。
public enum AlbumFlowCoverVarietyPolicy {
    public struct Card: Equatable, Sendable {
        /// 在播放队列里的位置。
        public let position: Int
        /// 这张卡原本的专辑。
        public let album: String

        public init(position: Int, album: String) {
            self.position = position
            self.album = album
        }
    }

    /// 曲库里至少有这么多张别的专辑才换,太少时换来换去都是那一两张,不如不换。
    public static let minimumPoolSize = 2

    /// - Parameters:
    ///   - centerAlbum: 中间正在播的这首的专辑。
    ///   - before: 左边的卡,由近到远。
    ///   - after: 右边的卡,由近到远。
    ///   - pool: 可以换上的曲库专辑,顺序固定(换上的图按它取,顺序一变就会换图)。
    /// - Returns: 两边每张卡换成 `pool` 里的第几个;nil 是保留原封面。
    public static func substitutes(
        centerAlbum: String,
        before: [Card],
        after: [Card],
        pool: [String]
    ) -> (before: [Int?], after: [Int?]) {
        let candidates = pool.indices.filter { pool[$0] != centerAlbum }
        guard candidates.count >= minimumPoolSize else {
            return (before.map { _ in nil }, after.map { _ in nil })
        }
        func side(_ cards: [Card]) -> [Int?] {
            var nearerAlbum = centerAlbum
            return cards.map { card in
                defer { nearerAlbum = card.album }
                guard card.album == nearerAlbum else { return nil }
                return pick(for: card, candidates: candidates, pool: pool)
            }
        }
        return (side(before), side(after))
    }

    /// 相邻位置取相邻的候选,一屏里的卡不重样(候选够多时);恰好取到卡片自己那张专辑时
    /// 跳到候选的另一半,免得换了等于没换。
    private static func pick(for card: Card, candidates: [Int], pool: [String]) -> Int {
        let count = candidates.count
        let slot = ((card.position % count) + count) % count
        let index = candidates[slot]
        guard pool[index] == card.album else { return index }
        return candidates[(slot + count / 2) % count]
    }
}
