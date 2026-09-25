import Foundation

/// 手机横屏（compact 宽度）普通播放模式的两栏几何。
///
/// 这套布局要在 375~466pt 的短边里同时放下顶部一排玻璃圆钮、左侧大封面，以及
/// 右栏的歌名 / 艺人 / 当前歌词行 / 进度条 / 传输键 / 可选音量条。任何一处散着
/// 算都会在某台设备上溢出，所以尺寸与「这一块还放不放得下」的判断全部集中在
/// 这里，视图层只消费结果。
///
/// 高度判断按最坏情况取值（歌名两行、艺人一行），因此判定为「放得下」的组合
/// 在实际内容更短时只会更宽松。
public enum NowPlayingCompactLandscapeLayoutPolicy {

    // MARK: - 固定尺寸
    //
    // 视图层必须用同一套常量画，否则「算得下」和「画得下」会对不上。

    /// 顶部玻璃圆钮直径，与 `ImmersiveGlassActionButton` 的默认值一致。
    public static let chromeButtonDiameter: Double = 44
    /// 圆钮排与下面内容之间的间距。
    public static let chromeBottomSpacing: Double = 8
    /// 内容区左右各自的固定内边距，安全区另算。
    public static let horizontalPadding: Double = 20
    /// 内容区上下各自的固定内边距，安全区另算。
    public static let topPadding: Double = 8
    public static let bottomPadding: Double = 8
    /// 封面列与右栏之间的间距。
    public static let columnSpacing: Double = 24
    /// 封面最多占内容宽度的比例。
    public static let artworkWidthFraction: Double = 0.38
    /// 封面边长的下限。高度实在不够时以高度为准，不再强撑这个值。
    public static let minimumArtworkSize: Double = 180

    /// 播放 / 暂停实心圆的直径，同时也是传输键这一行的高度。
    public static let primaryTransportDiameter: Double = 68
    /// 上一首 / 下一首玻璃胶囊的尺寸。
    public static let secondaryTransportWidth: Double = 64
    public static let secondaryTransportHeight: Double = 44
    /// 两端随机 / 循环小图标的命中尺寸。
    public static let edgeToggleWidth: Double = 44
    /// 传输键彼此之间的间距。
    public static let transportSpacing: Double = 10

    // MARK: - 右栏纵向各块的保守高度

    /// 歌名按两行留白：`.largeTitle` 粗体两行的行高上界。限成一行时按它的一半算。
    public static let titleBlockHeight: Double = 80
    public static let titleBottomSpacing: Double = 6
    /// 艺人 / 专辑一行（含尾部音质徽标）。
    public static let artistRowHeight: Double = 28
    public static let lyricLineTopSpacing: Double = 10
    /// 当前歌词行固定行高：有没有歌词都占这么高，布局不会上下跳。
    public static let lyricLineHeight: Double = 24
    public static let progressTopSpacing: Double = 14
    /// 进度条 = 44pt 命中区 + 4pt 间距 + caption2 的两端时间。
    public static let progressBarHeight: Double = 62
    public static let transportTopSpacing: Double = 8
    public static let volumeTopSpacing: Double = 10
    public static let volumeRowHeight: Double = 38

    /// 传输键这一行在给定组合下最少要多宽。
    ///
    /// 中间的上一首 / 播放 / 下一首之间有两道间距；两端各多一个开关时，开关与
    /// 中间那组之间还各有一个可压缩的 `Spacer`，两侧合计再多四道间距。
    public static func minimumTransportWidth(includesEdgeToggles: Bool) -> Double {
        let core = secondaryTransportWidth * 2 + primaryTransportDiameter
        if includesEdgeToggles {
            return core + edgeToggleWidth * 2 + transportSpacing * 6
        }
        return core + transportSpacing * 4
    }

    /// 动态字号倍率的取值范围。超出这个范围的输入会被夹住，避免异常值把布局
    /// 算成负数。上限取 2：再往上这套横屏构图已经完全放不下，继续按真实倍数算
    /// 只会得到一个没有意义的大数字，让步梯级照样停在最后一级。
    public static let minimumTextScale: Double = 0.8
    public static let maximumTextScale: Double = 2.0

    /// 大号文本样式随动态字号长得比正文慢：`.largeTitle` 从 34 涨到辅助功能一档的
    /// 44（1.29 倍），同一档正文是 17 → 28（1.65 倍）。歌名块按正文倍率算会高估，
    /// 所以只吃正文增量的一半。
    public static let titleScaleDamping: Double = 0.5

    /// 各动态字号等级下的正文倍率，下标与 SwiftUI `DynamicTypeSize.allCases` 对齐：
    /// 0…6 是 xSmall…xxxLarge，7…11 是 accessibility1…5。取值是 iOS 正文字号
    /// （14/15/16/17/19/21/23/28/33/40/47/53）相对默认 17pt 的比值，辅助功能档
    /// 超过上限的部分直接夹到 `maximumTextScale`。
    public static let dynamicTypeTextScales: [Double] = [
        0.82, 0.88, 0.94, 1.00, 1.12, 1.24, 1.35, 1.65, 1.94, 2.00, 2.00, 2.00,
    ]

    /// 把动态字号等级折算成字号倍率。越界或读不出来的等级一律按默认档（large）。
    public static func textScale(forDynamicTypeIndex index: Int) -> Double {
        guard dynamicTypeTextScales.indices.contains(index) else { return 1 }
        return dynamicTypeTextScales[index]
    }

    public struct Metrics: Equatable, Sendable {
        /// 左右内边距，已经把对应一侧的安全区算进去了（两侧可能不相等）。
        public let leadingInset: Double
        public let trailingInset: Double
        public let topInset: Double
        public let bottomInset: Double
        /// 顶部圆钮排本身的高度，以及它与下方内容的间距。
        public let chromeRowHeight: Double
        public let chromeBottomSpacing: Double
        /// 去掉左右内边距之后的可用宽度。
        public let contentWidth: Double
        /// 去掉上下内边距与顶部圆钮排之后的可用高度。
        public let availableContentHeight: Double
        /// 封面边长（正方形）。
        public let artworkSize: Double
        /// 封面列宽。封面是正方形且列宽贴着它，所以与 `artworkSize` 相同；
        /// 单独给出来是为了视图层不必再自己推一遍。
        public let artworkColumnWidth: Double
        public let columnSpacing: Double
        /// 右栏宽度。
        public let detailColumnWidth: Double
        /// 右栏按当前显示组合实际需要的高度。
        public let detailStackHeight: Double
        /// 当前歌词行的固定行高（已按字号倍率放大）。
        public let lyricLineHeight: Double
        /// 歌名最多几行。高度让步到最后一级时收成 1。
        public let titleLineLimit: Int
        public let showsLyricLine: Bool
        /// 传输键两端的随机 / 循环是否放得下。放不下时它们要从别的入口（更多
        /// 菜单）继续可达。
        public let showsEdgeToggles: Bool
        public let showsVolumeBar: Bool
    }

    /// - Parameters:
    ///   - prefersVolumeBar: 设置里「播放页显示音量条」是否打开。关着时一定不显示。
    ///   - textScale: 动态字号相对默认值的大致倍率，用来放大文字块的保守高度。
    public static func metrics(
        viewportWidth: Double,
        viewportHeight: Double,
        safeAreaTop: Double,
        safeAreaBottom: Double,
        safeAreaLeading: Double,
        safeAreaTrailing: Double,
        prefersVolumeBar: Bool,
        textScale: Double = 1
    ) -> Metrics {
        let scale = normalizedTextScale(textScale)

        let leadingInset = sanitized(safeAreaLeading) + horizontalPadding
        let trailingInset = sanitized(safeAreaTrailing) + horizontalPadding
        let topInset = sanitized(safeAreaTop) + topPadding
        let bottomInset = sanitized(safeAreaBottom) + bottomPadding

        let contentWidth = max(0, sanitized(viewportWidth) - leadingInset - trailingInset)
        let availableContentHeight = max(
            0,
            sanitized(viewportHeight) - topInset - bottomInset
                - chromeButtonDiameter - chromeBottomSpacing
        )

        // 右栏至少要放得下「不带随机 / 循环」的传输键，封面先给它让位。
        let detailFloor = minimumTransportWidth(includesEdgeToggles: false)
        let artworkWidthCap = max(0, contentWidth - columnSpacing - detailFloor)
        let preferredArtwork = contentWidth * artworkWidthFraction
        let widthBoundArtwork = max(
            min(preferredArtwork, artworkWidthCap),
            min(minimumArtworkSize, artworkWidthCap)
        )
        var artworkSize = max(0, min(widthBoundArtwork, availableContentHeight))
        var detailColumnWidth = max(0, contentWidth - artworkSize - columnSpacing)

        // 右栏差一点放不下两端的随机 / 循环时,封面让出这一点 —— 让完仍不小于封面下限才让。
        // 折叠屏外屏横握(一侧 84 的系统竖栏)正落在这一档;其它手机的右栏本来就放得下,取值不变。
        let togglesWidth = minimumTransportWidth(includesEdgeToggles: true)
        if detailColumnWidth < togglesWidth {
            let yielded = contentWidth - columnSpacing - togglesWidth
            if yielded >= minimumArtworkSize, yielded < artworkSize {
                artworkSize = yielded
                detailColumnWidth = togglesWidth
            }
        }

        let showsEdgeToggles = detailColumnWidth >= togglesWidth

        let titleScale = 1 + (scale - 1) * titleScaleDamping
        let twoLineTitle = titleBlockHeight * titleScale
        let oneLineTitle = twoLineTitle / 2
        let scaledArtist = artistRowHeight * scale
        let scaledLyricLine = lyricLineHeight * scale

        // 歌名之外那几块（间距 + 艺人 + 进度条 + 传输键）是必须留的。
        let fixedHeight = titleBottomSpacing + scaledArtist
            + progressTopSpacing + progressBarHeight
            + transportTopSpacing + primaryTransportDiameter
        let lyricBlockHeight = lyricLineTopSpacing + scaledLyricLine
        let volumeBlockHeight = volumeTopSpacing + volumeRowHeight

        // 让步梯级，从最想要的排到最后兜底的：先丢音量条，再把歌名收成一行，
        // 最后才丢歌词行。歌名排在歌词行前面是量出来的 —— 收一行省的高度比
        // 歌词行那一块还多，而大多数歌名本来就只有一行，收了往往看不出变化；
        // 反过来先丢歌词行，会在字号只比默认大一档时就把这一行整个拿掉。
        let candidates: [(title: Double, lineLimit: Int, lyric: Bool, volume: Bool)] = [
            (twoLineTitle, 2, true, prefersVolumeBar),
            (twoLineTitle, 2, true, false),
            (oneLineTitle, 1, true, false),
            (oneLineTitle, 1, false, false),
        ]
        var chosen = candidates[candidates.count - 1]
        var chosenHeight = chosen.title + fixedHeight
        for candidate in candidates {
            var required = candidate.title + fixedHeight
            if candidate.lyric { required += lyricBlockHeight }
            if candidate.volume { required += volumeBlockHeight }
            guard required <= availableContentHeight else { continue }
            chosen = candidate
            chosenHeight = required
            break
        }

        let showsLyricLine = chosen.lyric
        let showsVolumeBar = chosen.volume
        let titleLineLimit = chosen.lineLimit
        let detailStackHeight = chosenHeight

        return Metrics(
            leadingInset: leadingInset,
            trailingInset: trailingInset,
            topInset: topInset,
            bottomInset: bottomInset,
            chromeRowHeight: chromeButtonDiameter,
            chromeBottomSpacing: chromeBottomSpacing,
            contentWidth: contentWidth,
            availableContentHeight: availableContentHeight,
            artworkSize: artworkSize,
            artworkColumnWidth: artworkSize,
            columnSpacing: columnSpacing,
            detailColumnWidth: detailColumnWidth,
            detailStackHeight: detailStackHeight,
            lyricLineHeight: scaledLyricLine,
            titleLineLimit: titleLineLimit,
            showsLyricLine: showsLyricLine,
            showsEdgeToggles: showsEdgeToggles,
            showsVolumeBar: showsVolumeBar
        )
    }

    // MARK: - 整屏居中(系统竖栏的设备)

    /// 系统把工具栏竖排到一侧的设备(iPhone Duo 外屏横握)上,播放页不滚动,按苹果的做法整屏居中:
    /// 两栏两侧都只留固定内边距,只让开遮挡区(竖排的状态栏与前置摄像头)。返回两侧该按多宽的
    /// 安全区去算 `metrics` / `lyricsMetrics`:通常是 0 与 0;只有居中排出来的封面或右栏落进了
    /// 遮挡区,才退回真实安全区,整块照旧让开那条竖栏。顶部圆钮排另由视图层单独让开遮挡区。
    public static func centeredSideSafeArea(
        viewportWidth: Double,
        viewportHeight: Double,
        safeAreaTop: Double,
        safeAreaBottom: Double,
        safeAreaLeading: Double,
        safeAreaTrailing: Double,
        occlusions: [OcclusionAvoidancePolicy.Region],
        prefersVolumeBar: Bool,
        textScale: Double = 1
    ) -> (leading: Double, trailing: Double) {
        let fallback = (leading: sanitized(safeAreaLeading), trailing: sanitized(safeAreaTrailing))
        guard !occlusions.isEmpty else { return (0, 0) }
        let centered = metrics(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeAreaTop: safeAreaTop,
            safeAreaBottom: safeAreaBottom,
            safeAreaLeading: 0,
            safeAreaTrailing: 0,
            prefersVolumeBar: prefersVolumeBar,
            textScale: textScale
        )
        let columnsTop = centered.topInset + centered.chromeRowHeight + centered.chromeBottomSpacing
        let artworkTop = columnsTop + (centered.availableContentHeight - centered.artworkSize) / 2
        let artwork = OcclusionAvoidancePolicy.Region(
            x: centered.leadingInset,
            y: artworkTop,
            width: centered.artworkSize,
            height: centered.artworkSize
        )
        let detailTop = columnsTop + max(0, (centered.availableContentHeight - centered.detailStackHeight) / 2)
        let detail = OcclusionAvoidancePolicy.Region(
            x: centered.leadingInset + centered.artworkSize + centered.columnSpacing,
            y: detailTop,
            width: centered.detailColumnWidth,
            height: centered.detailStackHeight
        )
        let gap = chromeBottomSpacing
        let collides = occlusions.contains { region in
            [artwork, detail].contains { block in
                region.maxX + gap > block.minX && region.minX - gap < block.maxX
                    && region.maxY + gap > block.minY && region.minY - gap < block.maxY
            }
        }
        return collides ? fallback : (0, 0)
    }

    // MARK: - 歌词模式
    //
    // 歌词模式沿用同一副骨架：顶部圆钮排不动，右栏的进度条与传输键留在原位，
    // 只是左边的大封面换成歌词、缩成右栏顶上的一张小封面。换模式时手指要按的
    // 东西不挪位置，是这套构图的前提 —— 所以内边距、圆钮排、栏间距全部复用
    // 上面那一组常量，这里只决定两栏怎么分宽、右栏放得下什么。

    /// 歌词栏想占的内容宽度比例。歌词是这一屏的主角，比封面模式里的封面更宽。
    public static let lyricsPaneWidthFraction: Double = 0.56
    /// 为了摆下随机 / 循环而把右栏加宽时，歌词栏至少还要剩这么大比例。
    public static let minimumLyricsPaneWidthFraction: Double = 0.52
    /// 右栏宽度上限：再宽进度条就长得不成比例，多出来的给歌词。
    public static let maximumLyricsDetailWidth: Double = 360
    /// 右栏顶上那张小封面的边长，以及它与歌名之间的间距。
    public static let lyricsThumbnailSize: Double = 60
    public static let lyricsHeaderSpacing: Double = 12
    /// 小封面旁的歌名按两行 `.title3` 粗体留白；限成一行时按一半算。
    public static let lyricsTitleBlockHeight: Double = 52
    public static let lyricsArtistRowHeight: Double = 20

    public struct LyricsMetrics: Equatable, Sendable {
        public let contentWidth: Double
        public let availableContentHeight: Double
        /// 左侧歌词栏宽度。
        public let lyricsPaneWidth: Double
        public let columnSpacing: Double
        /// 右栏宽度。
        public let detailColumnWidth: Double
        public let thumbnailSize: Double
        /// 小封面 + 歌名 / 艺人这一行的保守高度。
        public let headerHeight: Double
        /// 右栏按当前显示组合实际需要的高度。
        public let detailStackHeight: Double
        public let titleLineLimit: Int
        public let showsEdgeToggles: Bool
        public let showsVolumeBar: Bool
    }

    /// 参数含义与 `metrics` 相同，两边算出来的内边距也相同。
    public static func lyricsMetrics(
        viewportWidth: Double,
        viewportHeight: Double,
        safeAreaTop: Double,
        safeAreaBottom: Double,
        safeAreaLeading: Double,
        safeAreaTrailing: Double,
        prefersVolumeBar: Bool,
        textScale: Double = 1
    ) -> LyricsMetrics {
        let scale = normalizedTextScale(textScale)

        let leadingInset = sanitized(safeAreaLeading) + horizontalPadding
        let trailingInset = sanitized(safeAreaTrailing) + horizontalPadding
        let topInset = sanitized(safeAreaTop) + topPadding
        let bottomInset = sanitized(safeAreaBottom) + bottomPadding

        let contentWidth = max(0, sanitized(viewportWidth) - leadingInset - trailingInset)
        let availableContentHeight = max(
            0,
            sanitized(viewportHeight) - topInset - bottomInset
                - chromeButtonDiameter - chromeBottomSpacing
        )

        let splittable = max(0, contentWidth - columnSpacing)
        let detailFloor = minimumTransportWidth(includesEdgeToggles: false)
        let toggleWidth = minimumTransportWidth(includesEdgeToggles: true)
        var detailColumnWidth = min(
            max(splittable * (1 - lyricsPaneWidthFraction), detailFloor),
            maximumLyricsDetailWidth
        )
        // 差一点就摆得下随机 / 循环时，宁可让歌词让出几十点，也不要把这两个键
        // 赶进「更多」菜单 —— 前提是歌词栏仍然明显是大的那一半。
        if detailColumnWidth < toggleWidth,
           toggleWidth <= maximumLyricsDetailWidth,
           splittable - toggleWidth >= contentWidth * minimumLyricsPaneWidthFraction {
            detailColumnWidth = toggleWidth
        }
        detailColumnWidth = min(detailColumnWidth, splittable)
        let lyricsPaneWidth = max(0, splittable - detailColumnWidth)
        let showsEdgeToggles = detailColumnWidth >= toggleWidth

        let titleScale = 1 + (scale - 1) * titleScaleDamping
        let twoLineHeader = max(
            lyricsThumbnailSize,
            lyricsTitleBlockHeight * titleScale + lyricsArtistRowHeight * scale
        )
        let oneLineHeader = max(
            lyricsThumbnailSize,
            lyricsTitleBlockHeight * titleScale / 2 + lyricsArtistRowHeight * scale
        )
        let fixedHeight = progressTopSpacing + progressBarHeight
            + transportTopSpacing + primaryTransportDiameter
        let volumeBlockHeight = volumeTopSpacing + volumeRowHeight

        let candidates: [(header: Double, lineLimit: Int, volume: Bool)] = [
            (twoLineHeader, 2, prefersVolumeBar),
            (twoLineHeader, 2, false),
            (oneLineHeader, 1, false),
        ]
        var chosen = candidates[candidates.count - 1]
        var chosenHeight = chosen.header + fixedHeight
        for candidate in candidates {
            var required = candidate.header + fixedHeight
            if candidate.volume { required += volumeBlockHeight }
            guard required <= availableContentHeight else { continue }
            chosen = candidate
            chosenHeight = required
            break
        }

        return LyricsMetrics(
            contentWidth: contentWidth,
            availableContentHeight: availableContentHeight,
            lyricsPaneWidth: lyricsPaneWidth,
            columnSpacing: columnSpacing,
            detailColumnWidth: detailColumnWidth,
            thumbnailSize: lyricsThumbnailSize,
            headerHeight: chosen.header,
            detailStackHeight: chosenHeight,
            titleLineLimit: chosen.lineLimit,
            showsEdgeToggles: showsEdgeToggles,
            showsVolumeBar: chosen.volume
        )
    }

    private static func normalizedTextScale(_ value: Double) -> Double {
        guard value.isFinite else { return 1 }
        return min(max(value, minimumTextScale), maximumTextScale)
    }

    private static func sanitized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }
}
