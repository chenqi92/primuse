import Foundation

// MARK: - 字号模型

/// 动态字号的十二档，与系统的 `DynamicTypeSize` 一一对应。Kit 不引 SwiftUI，所以自己列一份。
public enum LibraryDetailTypeSize: Int, CaseIterable, Comparable, Sendable {
    case xSmall, small, medium, large, xLarge, xxLarge, xxxLarge
    case accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

    public var isAccessibility: Bool { self >= .accessibility1 }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 详情页头部用到的几种文字样式。
public enum LibraryDetailTextStyle: CaseIterable, Sendable {
    case largeTitle, title1, title2, title3, headline, footnote

    /// 系统默认字体表（pt），从 xSmall 排到 accessibility5。
    public func pointSize(at size: LibraryDetailTypeSize) -> Double {
        let table: [Double]
        switch self {
        case .largeTitle: table = [31, 32, 33, 34, 36, 38, 40, 44, 48, 52, 56, 60]
        case .title1: table = [25, 26, 27, 28, 30, 32, 34, 38, 43, 48, 53, 58]
        case .title2: table = [19, 20, 21, 22, 24, 26, 28, 34, 39, 44, 50, 56]
        case .title3: table = [17, 18, 19, 20, 22, 24, 26, 31, 37, 43, 49, 55]
        case .headline: table = [14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53]
        case .footnote: table = [12, 12, 12, 13, 15, 17, 19, 23, 27, 33, 38, 44]
        }
        return table[size.rawValue]
    }

    /// 一行字占的高度，取保守上界。
    ///
    /// SF 的行高约为字号的 1.2–1.4 倍（小字号比例更大），一行里混了苹方时还会再高一点，
    /// 所以按 1.3 倍加 2 估，只会估多不会估少。
    public func lineHeight(at size: LibraryDetailTypeSize) -> Double {
        (pointSize(at: size) * 1.3 + 2).rounded(.up)
    }

    public func height(lines: Int, at size: LibraryDetailTypeSize) -> Double {
        Double(max(lines, 0)) * lineHeight(at: size)
    }
}

// MARK: - 输入与输出

/// 详情页此刻的视口。
public struct LibraryDetailHeroViewport: Equatable, Sendable {
    /// 页面宽度（左右安全区以内）。
    public var width: Double
    /// 页面整体高度（连同上下安全区）。
    public var height: Double
    /// 顶部安全区：状态栏 + 导航栏。头图铺到它下面，标题块与按钮排在它之下。
    public var topInset: Double
    /// 底部实际被盖住的高度：底部安全区（home 指示条、系统标签栏与附件），再加上不在安全区里的叠加式迷你条。
    public var bottomInset: Double
    public var isCompactHeight: Bool
    public var isRegularWidth: Bool
    public var typeSize: LibraryDetailTypeSize

    public init(
        width: Double,
        height: Double,
        topInset: Double,
        bottomInset: Double,
        isCompactHeight: Bool,
        isRegularWidth: Bool,
        typeSize: LibraryDetailTypeSize
    ) {
        self.width = width
        self.height = height
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.isCompactHeight = isCompactHeight
        self.isRegularWidth = isRegularWidth
        self.typeSize = typeSize
    }
}

/// 标题块的字号档。紧凑档在头图实在放不下时启用：标题降一级、限两行。
public enum LibraryDetailTitleTier: Sendable, Equatable {
    case regular
    case reduced
}

/// 「随机 · 播放 · 下载」这一排怎么排。
public enum LibraryDetailActionRowArrangement: Sendable, Equatable {
    /// 两颗圆钮夹着播放胶囊。
    case singleRow
    /// 播放胶囊独占一行，圆钮排在下一行。
    case twoRows
}

/// 手机横屏（紧凑高度）头部的排法。首屏只有两百点上下，操作行不能再单独占一行。
public enum LibraryDetailCompactHeaderStyle: Sendable, Equatable {
    /// 封面在前，右栏上面是标题块、下面是操作行，都靠前对齐。
    case besideArtwork
    /// 封面、标题块、操作行排成一行：字号大到右栏叠不下两层时用。
    case inline
}

/// 封面（或风格页的马赛克）与标题块叠在一起的那一段。
///
/// 封面边长到页面上才最终定下：标题块实际多高要排版以后才知道，所以这里给理想值、下限和整段的预算，
/// 视图层量完标题块再调 `resolvedExtent(identityHeight:)`。
public struct LibraryDetailArtworkStack: Equatable, Sendable {
    /// 封面的理想高度（专辑封面是边长，风格马赛克是高度）。
    public let ideal: Double
    /// 放不下时最多缩到这里。
    public let minimum: Double
    /// 封面 + 间距 + 标题块一共能用的高度。
    public let budget: Double
    /// 封面与标题块之间的间距。
    public let spacing: Double

    public init(ideal: Double, minimum: Double, budget: Double, spacing: Double) {
        self.ideal = ideal
        self.minimum = min(minimum, ideal)
        self.budget = budget
        self.spacing = spacing
    }

    /// 标题块量出来之后，封面实际取多高。
    public func resolvedExtent(identityHeight: Double) -> Double {
        let fitting = (budget - spacing - identityHeight).rounded(.down)
        return min(ideal, max(minimum, fitting))
    }

    /// 同一高度下这一段总共多高。
    public func stackHeight(identityHeight: Double) -> Double {
        resolvedExtent(identityHeight: identityHeight) + spacing + identityHeight
    }

    /// 横屏那几支用的定值：不量标题，封面固定。`spacing` 是封面与右栏之间的横向间距。
    static func fixed(_ extent: Double, spacing: Double) -> LibraryDetailArtworkStack {
        LibraryDetailArtworkStack(ideal: extent, minimum: extent, budget: .infinity, spacing: spacing)
    }
}

/// 五种详情页头部的几何。
public struct LibraryDetailHeroLayout: Equatable, Sendable {
    /// 首屏：顶部安全区以下、底部遮挡以上的那段高度。头图 + 标题块 + 操作行必须整个落在这里面。
    public let firstScreenHeight: Double
    public let isCompactHeight: Bool
    /// 手机横屏头部的排法；竖屏恒为 nil。
    public let compactStyle: LibraryDetailCompactHeaderStyle?
    public let titleTier: LibraryDetailTitleTier
    public let actionRow: LibraryDetailActionRowArrangement
    /// 操作行（随机 · 播放 · 下载）的高度，两行时是两行加起来。
    public let actionRowHeight: Double
    /// 头部文字与按钮的最大宽度。常规宽度（iPad、折叠屏内屏）下居中限宽，手机上不限。
    public let bodyMaxWidth: Double?

    public let album: LibraryDetailArtworkStack
    public let playlistCover: LibraryDetailArtworkStack
    public let smartPlaylistCover: LibraryDetailArtworkStack
    /// 风格页马赛克的高度（宽度是高度的 1.9 / 1.3）。
    public let genreMosaic: LibraryDetailArtworkStack
    /// 艺术家海报高度，不含顶部安全区。手机横屏下名字与按钮排成一行压在海报下沿。
    public let artistPosterHeight: Double
    /// 歌单页封面墙高度，不含顶部安全区。手机横屏下标题与操作行排成一行压在墙面下沿。
    public let playlistWallHeight: Double
    /// 智能歌单页封面墙高度（墙下还要放一段规则摘要）。
    public let smartPlaylistWallHeight: Double
}

// MARK: - 策略

/// 专辑、艺术家、歌单、智能歌单、风格五种详情页的头图几何。
///
/// 这些头图原来都是竖屏常量（封面 262、海报 440、封面墙 320），按 iPhone Pro 标定；
/// SE 与折叠屏外屏这类「宽而矮」的视口上，操作行会被标签栏和迷你条压住一半。
/// 这里按首屏高度统一取值，**不变量：头图 + 标题块 + 操作行 ≤ 首屏 − 16**，
/// 放得下的机型保持原来的尺寸不动。
///
/// 手机横屏（紧凑高度）首屏只有 SE 177、15 Pro 195、Pro Max 242 点，同一个不变量靠换排法守住：
/// 封面类头部把操作行挪进封面右栏（`LibraryDetailCompactHeaderStyle`），
/// 艺术家海报与封面墙把标题和操作行排成一行、压在下沿的渐隐段上，头图高度按首屏收。
public enum LibraryDetailHeroLayoutPolicy {
    // MARK: 让位与留白

    /// 操作行底下至少留出的空隙。
    public static let firstScreenMargin: Double = 16
    /// 竖屏底部遮挡的下限（从屏幕底边量起）。
    ///
    /// 两种外壳里取较高的那个，同一个详情页在两种外观下头图一样大：
    /// 经典 iOS 26 起是悬浮标签栏 + 附件迷你条，SE 与 Pro 实测都是 139；
    /// 极简的通栏停靠条 SE 85、Pro 120。iOS 18–26.0 经典的叠加式迷你条不在安全区里，
    /// 由页面按实测（安全区 + 叠加条）传进来，可能比它高。
    public static let portraitBottomChromeFloor: Double = 139
    /// 横屏底部遮挡的下限：经典的标签栏 + 附件迷你条实测 120（Pro 横屏），极简停靠条 76。
    public static let landscapeBottomChromeFloor: Double = 120
    /// 叠加式迷你条（iOS 18–26.0 经典外观）盖住的高度，与各页原来的底部留白一致。
    public static let legacyMiniPlayerOverlay: Double = 64

    // MARK: 取值系数（按首屏高度 F）

    /// 专辑封面：`min(宽 − 48, clamp(F × 0.48, 150, 262))`，再按标题块实际高度收。
    public static let albumCoverRatio: Double = 0.48
    public static let albumCoverRange: ClosedRange<Double> = 150...262
    /// 歌单单封面：`clamp(F × 0.44, 140, 240)`。
    public static let playlistCoverRatio: Double = 0.44
    public static let playlistCoverRange: ClosedRange<Double> = 140...240
    /// 智能歌单色块：`clamp(F × 0.36, 120, 200)`。
    public static let smartCoverRatio: Double = 0.36
    public static let smartCoverRange: ClosedRange<Double> = 120...200
    /// 风格马赛克高度：原来是 132 × 1.3，放得下就不变。
    public static let genreMosaicIdeal: Double = 132 * 1.3
    /// 艺术家海报：`clamp(F × 0.75, 240, 440)`。
    public static let artistPosterRatio: Double = 0.75
    public static let artistPosterRange: ClosedRange<Double> = 240...440
    /// 封面墙：`clamp(F × 0.58, 220, 320)`，再扣掉墙下内容的预算。
    public static let wallRatio: Double = 0.58
    public static let wallRange: ClosedRange<Double> = 220...320
    /// 标题块量出来以后封面最多缩到这里。
    public static let minimumArtworkSide: Double = 88
    /// 封面低于这个边长就改用紧凑的标题档。
    public static let comfortableArtworkSide: Double = 150
    /// 常规宽度下头部文字与按钮的最大宽度。
    public static let regularBodyMaxWidth: Double = 720
    /// 窄于这个宽度，操作行改两行。
    public static let singleRowMinimumWidth: Double = 360
    /// 智能歌单的色块只是个图标底，可以比封面缩得更小。
    public static let minimumSmartCoverSide: Double = 64

    // MARK: 固定尺寸（与视图层同一套常量）

    public static let circleButtonSide: Double = 54
    public static let actionRowSpacing: Double = 14
    public static let actionRowLineSpacing: Double = 12
    public static let artistPlayCircle: Double = 80

    /// 竖屏头部各段的间距。
    public enum Spacing {
        public static let albumTop: Double = 16
        public static let albumArtworkToIdentity: Double = 22
        public static let albumIdentityToActions: Double = 22
        public static let reducedArtworkToIdentity: Double = 16
        public static let reducedIdentityToActions: Double = 16
        public static let playlistTop: Double = 16
        public static let playlistArtworkToIdentity: Double = 20
        public static let playlistHeroToActions: Double = 18
        public static let smartHeroToSummary: Double = 14
        public static let smartSummaryToActions: Double = 18
        public static let genreTop: Double = 24
        public static let genreArtworkToIdentity: Double = 20
        public static let genreIdentityToActions: Double = 20
        public static let artistNameToSummary: Double = 10
        public static let artistSummaryToButtons: Double = 18
        public static let artistBottom: Double = 16
    }

    // MARK: 横屏（紧凑高度）

    public enum Compact {
        /// 头部上沿（顶部安全区以下）与下沿的留白。
        public static let top: Double = 12
        public static let bottom: Double = 12
        /// 封面与右栏之间的横向间距。
        public static let artworkToColumn: Double = 18
        /// 右栏里标题块与操作行之间。
        public static let identityToActions: Double = 12
        /// 封面边长跟着右栏高度走，夹在这个区间里。
        public static let artworkSideRange: ClosedRange<Double> = 112...168
        /// 风格马赛克的高度区间（宽是高的 1.9 / 1.3）。
        public static let genreMosaicRange: ClosedRange<Double> = (72 * 1.3)...120
        /// 艺术家海报最高 230（原来的横屏取值），矮屏按首屏收。
        public static let artistPosterMaximum: Double = 230
        /// 封面墙按首屏的这个比例取，夹在区间里：留一截给第一首歌，看得出下面还有内容。
        public static let wallRatio: Double = 0.72
        public static let wallRange: ClosedRange<Double> = 150...200
        /// 压在海报 / 墙面下沿的那一行离下沿多远。
        public static let overlayBottom: Double = 10
        /// 艺术家那一行的圆钮：随机 / 快捷收藏 48，播放 64。
        public static let artistCircle: Double = 48
        public static let artistPlayCircle: Double = 64
        /// 名字与摘要之间。
        public static let artistNameToSummary: Double = 4
    }

    // MARK: - 计算

    public static func bottomClearance(for viewport: LibraryDetailHeroViewport) -> Double {
        let floor = viewport.isCompactHeight ? landscapeBottomChromeFloor : portraitBottomChromeFloor
        return max(viewport.bottomInset, floor)
    }

    public static func firstScreenHeight(for viewport: LibraryDetailHeroViewport) -> Double {
        max(0, viewport.height - viewport.topInset - bottomClearance(for: viewport))
    }

    public static func actionRowArrangement(
        for viewport: LibraryDetailHeroViewport
    ) -> LibraryDetailActionRowArrangement {
        guard !viewport.isCompactHeight else { return .singleRow }
        // 无障碍字号下胶囊里的字会撑宽；常规宽度（iPad、折叠屏内屏）一行照样放得下。
        let crowdedByType = viewport.typeSize.isAccessibility && !viewport.isRegularWidth
        return crowdedByType || viewport.width < singleRowMinimumWidth ? .twoRows : .singleRow
    }

    /// 播放胶囊的高度：至少 54，大字号下跟着字撑高。
    public static func playPillHeight(_ typeSize: LibraryDetailTypeSize) -> Double {
        max(circleButtonSide, LibraryDetailTextStyle.headline.lineHeight(at: typeSize) + 12)
    }

    public static func actionRowHeight(
        _ arrangement: LibraryDetailActionRowArrangement,
        typeSize: LibraryDetailTypeSize
    ) -> Double {
        let pill = playPillHeight(typeSize)
        switch arrangement {
        case .singleRow: return pill
        case .twoRows: return pill + actionRowLineSpacing + circleButtonSide
        }
    }

    public static func layout(for viewport: LibraryDetailHeroViewport) -> LibraryDetailHeroLayout {
        let first = firstScreenHeight(for: viewport)
        guard !viewport.isCompactHeight else {
            return compactLayout(firstScreen: first, typeSize: viewport.typeSize)
        }

        let typeSize = viewport.typeSize
        let arrangement = actionRowArrangement(for: viewport)
        let actions = actionRowHeight(arrangement, typeSize: typeSize)
        let usable = first - firstScreenMargin
        let widthCap = max(0, viewport.width - 48)

        // 先按常规标题档估一遍：标题两行时封面还剩不到舒适边长，就换紧凑档。
        let regularAlbum = albumStack(usable: usable, actions: actions, widthCap: widthCap,
                                      first: first, tier: .regular)
        let regularFit = regularAlbum.resolvedExtent(
            identityHeight: estimatedIdentityHeight(.album, tier: .regular, typeSize: typeSize, titleLines: 2)
        )
        let tier: LibraryDetailTitleTier = regularFit < min(comfortableArtworkSide, regularAlbum.ideal)
            ? .reduced : .regular

        let album = tier == .regular
            ? regularAlbum
            : albumStack(usable: usable, actions: actions, widthCap: widthCap, first: first, tier: .reduced)

        let artworkSpacing: (Double) -> Double = { tier == .regular ? $0 : Spacing.reducedArtworkToIdentity }

        let playlistCover = LibraryDetailArtworkStack(
            ideal: min(widthCap, clamp(first * playlistCoverRatio, playlistCoverRange)),
            minimum: minimumArtworkSide,
            budget: usable - Spacing.playlistTop - Spacing.playlistHeroToActions - actions,
            spacing: artworkSpacing(Spacing.playlistArtworkToIdentity)
        )

        let smartSummary = LibraryDetailTextStyle.footnote.height(lines: smartSummaryLineLimit(tier), at: typeSize)
        let smartBelow = Spacing.smartHeroToSummary + smartSummary + Spacing.smartSummaryToActions + actions
        let smartCover = LibraryDetailArtworkStack(
            ideal: min(widthCap, clamp(first * smartCoverRatio, smartCoverRange)),
            minimum: minimumSmartCoverSide,
            budget: usable - Spacing.playlistTop - smartBelow,
            spacing: artworkSpacing(Spacing.playlistArtworkToIdentity)
        )

        let genre = LibraryDetailArtworkStack(
            ideal: genreMosaicIdeal,
            minimum: minimumArtworkSide * 0.8,
            budget: usable - Spacing.genreTop - Spacing.genreIdentityToActions - genreActionRowHeight(arrangement, typeSize: typeSize),
            spacing: artworkSpacing(Spacing.genreArtworkToIdentity)
        )

        // 艺术家：名字、摘要和按钮压在海报下缘，海报底边就是操作行底边再加 16。
        let artistBlock = estimatedArtistBlockHeight(tier: tier, typeSize: typeSize)
        let poster = min(
            first,
            max(clamp(first * artistPosterRatio, artistPosterRange), min(first, artistBlock + 60))
        )

        let wallCap = clamp(first * wallRatio, wallRange)
        let playlistWall = min(wallCap, usable - Spacing.playlistHeroToActions - actions)
        let smartWall = min(wallCap, usable - smartBelow)

        return LibraryDetailHeroLayout(
            firstScreenHeight: first,
            isCompactHeight: false,
            compactStyle: nil,
            titleTier: tier,
            actionRow: arrangement,
            actionRowHeight: actions,
            bodyMaxWidth: viewport.isRegularWidth ? regularBodyMaxWidth : nil,
            album: album,
            playlistCover: playlistCover,
            smartPlaylistCover: smartCover,
            genreMosaic: genre,
            artistPosterHeight: poster.rounded(.down),
            playlistWallHeight: max(0, playlistWall).rounded(.down),
            smartPlaylistWallHeight: max(0, smartWall).rounded(.down)
        )
    }

    /// 视图还没量出尺寸时（第一帧之前）用的取值：Pro 竖屏、默认字号，也就是原来的常量。
    public static let standard: LibraryDetailHeroLayout = layout(for: LibraryDetailHeroViewport(
        width: 402, height: 874, topInset: 116, bottomInset: 147,
        isCompactHeight: false, isRegularWidth: false, typeSize: .large
    ))

    // MARK: - 估算（测试与标题档判断用）

    /// 智能歌单封面下那段规则摘要最多几行。紧凑档（无障碍字号）只留一行。
    public static func smartSummaryLineLimit(_ tier: LibraryDetailTitleTier) -> Int {
        tier == .regular ? 3 : 1
    }

    public enum HeroKind: CaseIterable, Sendable {
        case album, playlistCover, smartCover, genre
    }

    /// 标题块的估算高度：标题按给定行数，其余各行按一行。
    public static func estimatedIdentityHeight(
        _ kind: HeroKind,
        tier: LibraryDetailTitleTier,
        typeSize: LibraryDetailTypeSize,
        titleLines: Int
    ) -> Double {
        switch kind {
        case .album:
            // 标题 / 艺术家 / 流派·年份·格式，行距 4，信息行上面再多 2。
            let title = albumTitleStyle(tier).height(lines: titleLines, at: typeSize)
            let artist = albumArtistStyle(tier).lineHeight(at: typeSize)
            let meta = LibraryDetailTextStyle.footnote.lineHeight(at: typeSize)
            return title + 4 + artist + 4 + 2 + meta
        case .playlistCover, .smartCover:
            let title = albumTitleStyle(tier).height(lines: titleLines, at: typeSize)
            return title + 5 + LibraryDetailTextStyle.footnote.lineHeight(at: typeSize)
        case .genre:
            let title = genreTitleStyle(tier).height(lines: titleLines, at: typeSize)
            return title + 4 + LibraryDetailTextStyle.footnote.lineHeight(at: typeSize)
        }
    }

    /// 艺术家海报下缘那一块：名字（最多两行）+ 摘要（大字号按两行）+ 三颗圆钮 + 底边留白。
    public static func estimatedArtistBlockHeight(
        tier: LibraryDetailTitleTier,
        typeSize: LibraryDetailTypeSize
    ) -> Double {
        let name = artistNameStyle(tier).height(lines: 2, at: typeSize)
        let summary = LibraryDetailTextStyle.footnote.height(
            lines: typeSize >= .xxxLarge ? 2 : 1,
            at: typeSize
        )
        return name + Spacing.artistNameToSummary + summary + Spacing.artistSummaryToButtons
            + artistPlayCircle + Spacing.artistBottom
    }

    public static func albumTitleStyle(_ tier: LibraryDetailTitleTier) -> LibraryDetailTextStyle {
        tier == .regular ? .title2 : .title3
    }

    public static func albumArtistStyle(_ tier: LibraryDetailTitleTier) -> LibraryDetailTextStyle {
        tier == .regular ? .title3 : .headline
    }

    public static func artistNameStyle(_ tier: LibraryDetailTitleTier) -> LibraryDetailTextStyle {
        tier == .regular ? .largeTitle : .title1
    }

    public static func genreTitleStyle(_ tier: LibraryDetailTitleTier) -> LibraryDetailTextStyle {
        tier == .regular ? .largeTitle : .title1
    }

    /// 专辑页标题块与操作行之间的间距。
    public static func albumIdentityToActions(_ tier: LibraryDetailTitleTier) -> Double {
        tier == .regular ? Spacing.albumIdentityToActions : Spacing.reducedIdentityToActions
    }

    /// 标题最多几行。
    public static func titleLineLimit(_ tier: LibraryDetailTitleTier) -> Int {
        tier == .regular ? 3 : 2
    }

    /// 手机横屏下标题只排一行（右栏有五六百点宽，放不下的按比例缩一点再截断）。
    public static let compactTitleLineLimit = 1

    /// 手机横屏压在海报下沿那一行的高度：名字（一行）+ 摘要，与三颗圆钮取高的那个。
    public static func estimatedArtistCompactRowHeight(typeSize: LibraryDetailTypeSize) -> Double {
        let name = artistNameStyle(.reduced).lineHeight(at: typeSize)
        let summary = LibraryDetailTextStyle.footnote.lineHeight(at: typeSize)
        let text = name + Compact.artistNameToSummary + summary
        return max(text, Compact.artistPlayCircle)
    }

    /// 手机横屏压在封面墙下沿那一行的高度：标题（一行）+ 摘要，与操作行取高的那个。
    public static func estimatedWallCompactRowHeight(
        typeSize: LibraryDetailTypeSize
    ) -> Double {
        let title = LibraryDetailTextStyle.title2.lineHeight(at: typeSize)
        let summary = LibraryDetailTextStyle.footnote.lineHeight(at: typeSize)
        return max(title + 6 + summary, actionRowHeight(.singleRow, typeSize: typeSize))
    }

    /// 风格页只有「随机 · 播放」两颗，两行排时第二行只有一颗圆钮，高度一样。
    public static func genreActionRowHeight(
        _ arrangement: LibraryDetailActionRowArrangement,
        typeSize: LibraryDetailTypeSize
    ) -> Double {
        actionRowHeight(arrangement, typeSize: typeSize)
    }

    // MARK: - 私有

    private static func albumStack(
        usable: Double,
        actions: Double,
        widthCap: Double,
        first: Double,
        tier: LibraryDetailTitleTier
    ) -> LibraryDetailArtworkStack {
        LibraryDetailArtworkStack(
            ideal: min(widthCap, clamp(first * albumCoverRatio, albumCoverRange)),
            minimum: minimumArtworkSide,
            budget: usable - Spacing.albumTop - albumIdentityToActions(tier) - actions,
            spacing: tier == .regular ? Spacing.albumArtworkToIdentity : Spacing.reducedArtworkToIdentity
        )
    }

    /// 手机横屏：先试「操作行挪进封面右栏」，右栏叠不下两层（大字号）时封面、标题、操作行排成一行；
    /// 两种排法都先用常规标题档，放不下再降一档。专辑的标题块最高（标题 + 艺术家 + 信息行），按它来定。
    private static func compactLayout(
        firstScreen: Double,
        typeSize: LibraryDetailTypeSize
    ) -> LibraryDetailHeroLayout {
        let actions = actionRowHeight(.singleRow, typeSize: typeSize)
        let usable = firstScreen - firstScreenMargin - Compact.top
        let identity: (LibraryDetailTitleTier) -> Double = { tier in
            estimatedIdentityHeight(.album, tier: tier, typeSize: typeSize, titleLines: compactTitleLineLimit)
        }

        var choice: (style: LibraryDetailCompactHeaderStyle, tier: LibraryDetailTitleTier, column: Double)?
        for tier in [LibraryDetailTitleTier.regular, .reduced] {
            let column = identity(tier) + Compact.identityToActions + actions
            if column <= usable {
                choice = (.besideArtwork, tier, column)
                break
            }
        }
        if choice == nil {
            for tier in [LibraryDetailTitleTier.regular, .reduced] {
                let row = max(identity(tier), actions)
                if row <= usable || tier == .reduced {
                    choice = (.inline, tier, row)
                    break
                }
            }
        }
        let resolved = choice ?? (.inline, .reduced, max(identity(.reduced), actions))

        // 封面与右栏齐高：右栏多高封面就多大，夹在区间里，也不超出首屏。
        let side = min(clamp(resolved.column, Compact.artworkSideRange), max(Compact.artworkSideRange.lowerBound, usable))
            .rounded(.down)
        let mosaic = min(clamp(side * 0.8, Compact.genreMosaicRange), side).rounded(.down)
        let spacing = Compact.artworkToColumn

        // 海报与墙面：标题和操作行压在下沿，底边离首屏下沿至少 16。
        let overlayCeiling = firstScreen - firstScreenMargin + Compact.overlayBottom
        let poster = min(Compact.artistPosterMaximum, overlayCeiling)
        let wall = min(clamp(firstScreen * Compact.wallRatio, Compact.wallRange), overlayCeiling)

        return LibraryDetailHeroLayout(
            firstScreenHeight: firstScreen,
            isCompactHeight: true,
            compactStyle: resolved.style,
            titleTier: resolved.tier,
            actionRow: .singleRow,
            actionRowHeight: actions,
            bodyMaxWidth: nil,
            album: .fixed(side, spacing: spacing),
            playlistCover: .fixed(side, spacing: spacing),
            smartPlaylistCover: .fixed(side, spacing: spacing),
            genreMosaic: .fixed(mosaic, spacing: spacing),
            artistPosterHeight: max(0, poster).rounded(.down),
            playlistWallHeight: max(0, wall).rounded(.down),
            smartPlaylistWallHeight: max(0, wall).rounded(.down)
        )
    }

    private static func clamp(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
