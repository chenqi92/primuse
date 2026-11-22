import CoreGraphics
import Foundation
import PrimuseKit
import SwiftUI

// 「水彩绘本」：暖色纸面上晕开几团封面色的水彩，封面像贴在绘本里的一幅画，墨线一秒换十二笔
// （动画里「一拍两张」那种抖动），有频谱时鼓点上封面弹一下、旁边冒出几个小涂鸦；歌词写在一条水彩带上。
//
// 和 ImmersiveStageView 一样同时编进 Primuse(iOS)、PrimuseMac 与 PrimuseTV。水彩的形状每首歌按歌名算一次，
// 在后台画成几张蒙版，之后每帧只挪位置、缩放；封面描边和涂鸦的几种抖法也是先算好的，播放时只按时间挑一种。

// MARK: - 颜色

enum ImmersiveWatercolorInk {
    /// 偏暖的深褐墨色：歌名、描边、涂鸦，歌词也乘成这个颜色。
    static let ink = Color(red: 0.16, green: 0.12, blue: 0.10)
    /// 纸的底色。
    static let paper = Color(red: 0.965, green: 0.937, blue: 0.878)
    /// 纸边压暗用的褐色。
    static let umber = Color(red: 0.42, green: 0.30, blue: 0.20)
}

// MARK: - 场景

/// 水彩绘本的整幅画面。歌词由舞台给（`lyrics`，白字），这里乘成墨色、垫上水彩带；没有歌词时歌名放大。
struct ImmersiveWatercolorStoryScene<Artwork: View, Lyrics: View>: View {
    @Environment(\.immersiveFrameRate) private var frameRate

    let metrics: ImmersiveStageMetrics
    let platform: ImmersiveStagePlatform
    let palette: ImmersiveArtworkPalette
    let title: String
    let subtitle: String
    /// 换歌时换一套水彩、倾角和涂鸦位置；同一首歌每次都一样。
    let songKey: String
    /// 舞台的内容边距：上沿、两侧安全区，下沿含控件让出的高度。文字不出这个范围。
    let insets: EdgeInsets
    let hasLyrics: Bool
    /// 装饰动画在不在跑：暂停、减弱动态效果、省电档、不在屏幕上时为 false，墨线不抖、封面不弹。
    let isAnimating: Bool
    let isResting: Bool
    /// 不建立观察的那份频谱，只在按时间表画的那一层里读。
    let levelsProvider: @MainActor () -> [CGFloat]
    let lyrics: (ImmersiveAlbumFlowGeometry.LyricFonts, CGFloat) -> Lyrics
    let artwork: (CGFloat) -> Artwork

    @State private var model = ImmersiveWatercolorStoryModel()

    var body: some View {
        let layout = ImmersiveWatercolorStoryLayout(metrics: metrics, platform: platform, insets: insets)
        let plan = model.plan(for: songKey)
        ZStack(alignment: .topLeading) {
            ImmersiveWatercolorPaper(palette: palette)
            ImmersiveWatercolorWashes(
                songKey: songKey,
                placements: plan.pools(for: layout, canvas: metrics.size),
                palette: palette,
                isAnimating: isAnimating
            )
            ImmersiveVignette(
                color: ImmersiveWatercolorInk.umber.opacity(0.36),
                center: .center,
                clearStop: 0.42,
                strength: 0.45
            )
            .blendMode(.multiply)
            handDrawnLayer(layout: layout, plan: plan)
            textBlock(layout: layout, plan: plan)
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
    }

    // MARK: 封面与涂鸦

    /// 墨线一秒换十二笔，弹跳最多三十帧就够顺：帧率档位再高也不超过三十帧。
    private var handDrawnInterval: TimeInterval {
        max(frameRate.minimumInterval(base: 1.0 / 12) ?? 0, 1.0 / 30)
    }

    private func handDrawnLayer(
        layout: ImmersiveWatercolorStoryLayout,
        plan: ImmersiveWatercolorStoryPlan
    ) -> some View {
        let region = doodleRegion(layout: layout)
        let slots = plan.doodleSlots(for: layout, in: region, canvas: metrics.size)
        let side = layout.coverSide
        return TimelineView(.animation(minimumInterval: handDrawnInterval, paused: !isAnimating)) { context in
            let frame = model.frame(
                time: context.date.timeIntervalSinceReferenceDate,
                levels: isAnimating ? levelsProvider() : [],
                animates: isAnimating
            )
            ZStack(alignment: .topLeading) {
                ImmersiveWatercolorCover(
                    side: side,
                    plan: plan,
                    palette: palette,
                    boil: frame.boil,
                    artwork: artwork
                )
                .rotationEffect(.degrees(plan.coverTilt))
                .scaleEffect(x: frame.stretch.width, y: frame.stretch.height, anchor: .bottom)
                .offset(y: -frame.hop * side)
                .position(layout.coverCenter)

                ImmersiveWatercolorDoodles(
                    doodles: frame.doodles,
                    time: frame.time,
                    boil: frame.boil,
                    slots: slots,
                    size: layout.doodleSize,
                    accent: palette.primary
                )
                .frame(width: region.width, height: region.height)
                .position(x: region.midX, y: region.midY)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// 涂鸦只在封面周围冒：画布取封面外扩一圈，和舞台求交，整块重画的面积小。
    private func doodleRegion(layout: ImmersiveWatercolorStoryLayout) -> CGRect {
        let side = layout.coverSide
        let reach = side * 0.5 + side * 0.78 + layout.doodleSize
        let around = CGRect(
            x: layout.coverCenter.x - reach,
            y: layout.coverCenter.y - reach,
            width: reach * 2,
            height: reach * 2
        )
        let stage = CGRect(origin: .zero, size: metrics.size)
        let region = around.intersection(stage)
        return region.isNull || region.isEmpty ? stage : region
    }

    // MARK: 歌名与歌词带

    @ViewBuilder
    private func textBlock(layout: ImmersiveWatercolorStoryLayout, plan: ImmersiveWatercolorStoryPlan) -> some View {
        let frame = layout.textFrame
        Group {
            if layout.isStacked {
                // 竖着排：歌名紧跟在封面下面，歌词带落在控件上方。
                VStack(spacing: 0) {
                    if hasLyrics {
                        titleView(size: layout.titleSize, layout: layout, plan: plan)
                        Spacer(minLength: metrics.s(10))
                        band(layout: layout, plan: plan)
                    } else {
                        Spacer(minLength: 0)
                        titleView(size: layout.titleSize * 1.3, layout: layout, plan: plan)
                        Spacer(minLength: 0)
                    }
                }
            } else {
                VStack(spacing: metrics.s(platform == .tvOS ? 44 : 30)) {
                    titleView(
                        size: hasLyrics ? layout.titleSize : layout.titleSize * 1.3,
                        layout: layout,
                        plan: plan
                    )
                    if hasLyrics {
                        band(layout: layout, plan: plan)
                    }
                }
            }
        }
        .frame(width: frame.width, height: frame.height)
        .position(x: frame.midX, y: frame.midY)
        .animation(.easeOut(duration: 0.4), value: hasLyrics)
    }

    /// 粗圆体墨色歌名，压一道封面色的错位阴影，略微歪着写；下面一行小字是歌手与专辑。
    private func titleView(
        size: CGFloat,
        layout: ImmersiveWatercolorStoryLayout,
        plan: ImmersiveWatercolorStoryPlan
    ) -> some View {
        let subtitleSize = max(size * 0.4, layout.secondaryFloor)
        let titleFloor = layout.titleFloor
        return VStack(spacing: size * 0.18) {
            Text(title)
                .font(.system(size: size, weight: .heavy, design: .rounded))
                .foregroundStyle(ImmersiveWatercolorInk.ink)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                // 放不下时缩小，但不小于读得清的下限。
                .minimumScaleFactor(min(1, titleFloor / max(size, 1)))
                .shadow(color: palette.primary.opacity(0.5), radius: 0, x: size * 0.05, y: size * 0.06)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: subtitleSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(ImmersiveWatercolorInk.ink.opacity(0.68))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(min(1, layout.secondaryFloor / max(subtitleSize, 1)))
            }
        }
        .frame(maxWidth: layout.textFrame.width)
        .rotationEffect(.degrees(plan.titleTilt))
        .accessibilityElement(children: .combine)
        .watercolorRestingText(isResting)
    }

    /// 歌词带：舞台给的当前句（逐字照样扫光）和淡一些的下一句，白字乘成墨色，后面垫一条歪歪的水彩。
    /// 带子的高度按字号固定，换句时不跟着伸缩。
    private func band(layout: ImmersiveWatercolorStoryLayout, plan: ImmersiveWatercolorStoryPlan) -> some View {
        let width = layout.textFrame.width
        let padding = layout.bandPadding
        let lyricWidth = max(width - padding.width * 2, 1)
        let lyricHeight = layout.lyricFonts.height
        let bandHeight = lyricHeight + padding.height * 2
        return lyrics(layout.lyricFonts, lyricWidth)
            .colorMultiply(ImmersiveWatercolorInk.ink)
            .frame(width: lyricWidth, height: lyricHeight)
            .padding(.horizontal, padding.width)
            .padding(.vertical, padding.height)
            .background {
                ImmersiveWatercolorBandWash(layers: plan.bandLayers, tint: palette.primary)
                    .frame(width: width * ImmersiveWatercolorStoryPlan.bandCanvasScale.width,
                           height: bandHeight * ImmersiveWatercolorStoryPlan.bandCanvasScale.height)
                    .rotationEffect(.degrees(plan.bandTilt))
                    .watercolorRestingText(isResting)
                    .accessibilityHidden(true)
            }
    }
}

private extension View {
    /// 和舞台的 `immersiveRestingText` 一样：休憩时淡出可读文字，位置不动，VoiceOver 也不再读到它。
    func watercolorRestingText(_ isResting: Bool) -> some View {
        opacity(isResting ? 0 : 1)
            .accessibilityHidden(isResting)
    }
}

// MARK: - 版式

/// 一种视口里封面、文字和歌词带各放在哪。竖屏（以及竖着拿的 iPad）封面在上、文字在下；
/// 其余封面贴前缘、竖直居中，歌名和歌词带在后面那一列。
struct ImmersiveWatercolorStoryLayout {
    let coverSide: CGFloat
    let coverCenter: CGPoint
    /// 歌名和歌词带那一块，已经让开舞台的边距。
    let textFrame: CGRect
    let isStacked: Bool
    let titleSize: CGFloat
    let titleFloor: CGFloat
    let secondaryFloor: CGFloat
    let lyricFonts: ImmersiveAlbumFlowGeometry.LyricFonts
    /// 歌词离水彩带边缘的距离（左右、上下）。
    let bandPadding: CGSize
    let doodleSize: CGFloat

    init(metrics: ImmersiveStageMetrics, platform: ImmersiveStagePlatform, insets: EdgeInsets) {
        let size = metrics.size
        let isTV = platform == .tvOS
        let stacked = metrics.isPortrait || (metrics.isWide && size.height > size.width * 1.05)
        isStacked = stacked

        // 字号按视口缩放，小画布上也不小于读得清的下限。
        let minimumTitle: CGFloat = metrics.isWide ? 34 : 26
        let minimumSecondary: CGFloat = metrics.isWide ? 15 : 13
        titleFloor = minimumTitle
        secondaryFloor = minimumSecondary
        let titleBase: CGFloat
        switch metrics.layout {
        case .phonePortrait: titleBase = metrics.s(30)
        case .phoneLandscape: titleBase = metrics.s(metrics.isHandheldLandscape ? 30 : 27)
        case .wide: titleBase = metrics.s(isTV ? 80 : 68)
        }
        let title = max(titleBase, minimumTitle)
        titleSize = title
        let fonts = Self.lyricFonts(metrics: metrics, isTV: isTV)
        lyricFonts = fonts
        let padding = metrics.isWide
            ? CGSize(width: metrics.s(isTV ? 40 : 32), height: metrics.s(isTV ? 24 : 20))
            : CGSize(width: metrics.s(18), height: metrics.s(12))
        bandPadding = padding
        doodleSize = metrics.s(metrics.isWide ? (isTV ? 64 : 54) : 30)

        let left = insets.leading
        let right = size.width - insets.trailing
        let top = insets.top
        let bottom = size.height - insets.bottom
        let innerWidth = max(right - left, 1)
        let bandHeight = fonts.height + padding.height * 2
        let subtitle = max(title * 0.4, minimumSecondary)
        let titleBlock = title * 1.22 * 2 + subtitle * 1.3 + metrics.s(6)

        if stacked {
            let gap = metrics.s(metrics.isWide ? 40 : 26)
            let textHeight = titleBlock + metrics.s(10) + bandHeight
            let available = max(bottom - top, 1)
            // iPhone Duo 内屏竖握方正得多，封面多占一些高度。
            let heightShare: CGFloat = metrics.isHandheldPortrait ? 0.5 : (metrics.isWide ? 0.46 : 0.44)
            let fitted = min(innerWidth * 0.8, available * heightShare, available - textHeight - gap - metrics.s(16))
            let side = max(fitted, metrics.s(120))
            coverSide = side
            let coverTop = top + metrics.s(16)
            coverCenter = CGPoint(x: size.width / 2, y: coverTop + side / 2)
            let textTop = coverTop + side + gap
            textFrame = CGRect(x: left, y: textTop, width: innerWidth, height: max(bottom - textTop, 1))
        } else {
            // 控件在文字那一侧（`showcaseControlAlignment`），封面这一侧往下用到安全区为止。
            let coverBottom = size.height - max(metrics.safeArea.bottom, metrics.s(14))
            let coverArea = max(coverBottom - top, 1)
            let isPhoneLandscape = metrics.layout == .phoneLandscape
            // iPhone Duo 内屏横握高出一大截，封面按宽度多占一些。
            let widthShare: CGFloat = isPhoneLandscape ? (metrics.isHandheldLandscape ? 0.46 : 0.38) : 0.36
            let fitted = min(coverArea * (isPhoneLandscape ? 0.84 : 0.72), innerWidth * widthShare)
            let side = max(fitted, metrics.s(120))
            coverSide = side
            let margin = side * 0.04
            coverCenter = CGPoint(x: left + margin + side / 2, y: top + coverArea / 2)
            let gap = metrics.s(isPhoneLandscape ? 40 : (isTV ? 110 : 80))
            let textLeft = left + margin * 2 + side + gap
            let width = max(right - textLeft, metrics.s(160))
            textFrame = CGRect(x: textLeft, y: top, width: width, height: max(bottom - top, 1))
        }
    }

    /// 歌词带里当前句与下一句的字号；手机横屏高度紧，只放当前这一句。
    private static func lyricFonts(metrics: ImmersiveStageMetrics, isTV: Bool) -> ImmersiveAlbumFlowGeometry.LyricFonts {
        switch metrics.layout {
        case .phonePortrait:
            return ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(21), 17), next: max(metrics.s(15), 13),
                currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(6)
            )
        case .phoneLandscape:
            if metrics.isHandheldLandscape {
                return ImmersiveAlbumFlowGeometry.LyricFonts(
                    current: max(metrics.s(21), 17), next: max(metrics.s(15), 13),
                    currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(6)
                )
            }
            return ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(19), 17), next: max(metrics.s(14), 13),
                currentLineLimit: 1, showsNextLine: false, spacing: 0
            )
        case .wide:
            if isTV {
                return ImmersiveAlbumFlowGeometry.LyricFonts(
                    current: max(metrics.s(46), 24), next: max(metrics.s(30), 16),
                    currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(12)
                )
            }
            return ImmersiveAlbumFlowGeometry.LyricFonts(
                current: max(metrics.s(38), 22), next: max(metrics.s(25), 15),
                currentLineLimit: 2, showsNextLine: true, spacing: metrics.s(10)
            )
        }
    }
}

// MARK: - 每首歌的手绘部分

/// 一团水彩每首歌的抖动：位置偏多少（画布比例）、大小倍数、转角与漂移的起始相位。
struct ImmersiveWatercolorPoolJitter {
    let dx: Double
    let dy: Double
    let scale: Double
    let rotation: Double
    let phase: Double
}

/// 一团水彩此刻画在哪、多大、什么颜色。蒙版本身是黑的，颜色在显示时上。
struct ImmersiveWatercolorPoolPlacement {
    let center: CGPoint
    let radius: CGFloat
    let usesSecondary: Bool
    /// 色相偏移（度）：邻近色。
    let hue: Double
    /// 提亮多少：淡一些的颜料。
    let lift: Double
    let opacity: Double
    let rotation: Double
    let phase: Double
    let drift: CGFloat
}

/// 涂鸦的一个落点（涂鸦画布里的坐标）、它歪多少、画哪一种。
struct ImmersiveWatercolorDoodleSlot {
    let point: CGPoint
    let turn: Double
    let kind: Int
}

/// 一首歌的手绘部分：封面的毛边形状与描边的几种抖法、封面和歌名的倾角、水彩带、几团水彩的位置抖动、
/// 涂鸦的落点。按歌名定种子，同一首每次都一样；整份只在换歌时算一次（`ImmersiveWatercolorStoryModel`）。
struct ImmersiveWatercolorStoryPlan {
    static let poolCount = 5
    /// 墨线先算好几种抖法，播放时按每秒十二帧轮着用。
    static let boilVariants = 3
    /// 水彩带的画布比带子本身大一圈，毛边伸出去不会被画布切直。
    static let bandCanvasScale = CGSize(width: 1.12, height: 1.4)

    let coverClip: [CGPoint]
    let coverOutlines: [[CGPoint]]
    let coverTilt: Double
    let titleTilt: Double
    let bandTilt: Double
    let bandLayers: [[CGPoint]]
    let poolJitter: [ImmersiveWatercolorPoolJitter]
    let doodleTurns: [Double]
    let doodleReach: [Double]
    let doodleSpins: [Double]
    let doodleKinds: [Int]

    init(songKey: String) {
        var random = ImmersiveRandom(seed: ImmersiveRandom.seed(for: songKey) ^ 0x57A7_E2C0_1095_B00C)
        // 封面歪不过 3°，歌名不过 2°，水彩带更平一些。
        coverTilt = min(max(random.centered() * 1.4, -3), 3)
        titleTilt = min(max(random.centered() * 0.8, -2), 2)
        bandTilt = min(max(random.centered() * 0.6, -1.2), 1.2)

        let clip = ImmersiveWatercolorGeometry.deckle(random: &random)
        coverClip = clip
        var outlines: [[CGPoint]] = []
        for _ in 0..<Self.boilVariants {
            outlines.append(ImmersiveWatercolorGeometry.redraw(clip, amount: 0.0045, random: &random))
        }
        coverOutlines = outlines
        bandLayers = ImmersiveWatercolorGeometry.bandLayers(random: &random)

        var jitter: [ImmersiveWatercolorPoolJitter] = []
        for _ in 0..<Self.poolCount {
            jitter.append(ImmersiveWatercolorPoolJitter(
                dx: (random.unit() - 0.5) * 0.08,
                dy: (random.unit() - 0.5) * 0.08,
                scale: 0.88 + random.unit() * 0.24,
                rotation: random.unit() * 360,
                phase: random.unit() * 2 * Double.pi
            ))
        }
        poolJitter = jitter

        var turns: [Double] = []
        var reach: [Double] = []
        var spins: [Double] = []
        var kinds: [Int] = []
        let firstKind = Int(random.unit() * Double(ImmersiveWatercolorGlyphs.kindCount))
        for index in 0..<Self.doodleSlotCount {
            turns.append(random.centered() * 8)
            reach.append(0.62 + random.unit() * 0.12)
            spins.append(random.centered() * 14)
            kinds.append((firstKind + index * 3) % ImmersiveWatercolorGlyphs.kindCount)
        }
        doodleTurns = turns
        doodleReach = reach
        doodleSpins = spins
        doodleKinds = kinds
    }

    static let doodleSlotCount = 8

    /// 几团水彩在这一版式里的位置：第一团垫在封面后面，其余铺在角上和文字那一侧，一部分伸出画布。
    func pools(for layout: ImmersiveWatercolorStoryLayout, canvas: CGSize) -> [ImmersiveWatercolorPoolPlacement] {
        let long = max(canvas.width, canvas.height)
        let anchors: [CGPoint] = layout.isStacked
            ? [CGPoint(x: 0.86, y: 0.88), CGPoint(x: 0.88, y: 0.12), CGPoint(x: 0.10, y: 0.66), CGPoint(x: 0.94, y: 0.50)]
            : [CGPoint(x: 0.10, y: 0.90), CGPoint(x: 0.84, y: 0.14), CGPoint(x: 0.68, y: 0.80), CGPoint(x: 0.44, y: 0.04)]
        let styles = ImmersiveWatercolorPoolStyle.all
        var result: [ImmersiveWatercolorPoolPlacement] = []
        for index in 0..<min(Self.poolCount, styles.count, poolJitter.count) {
            let style = styles[index]
            let jitter = poolJitter[index]
            let center: CGPoint
            let radius: CGFloat
            if index == 0 {
                center = CGPoint(
                    x: layout.coverCenter.x + CGFloat(jitter.dx) * layout.coverSide,
                    y: layout.coverCenter.y + CGFloat(jitter.dy) * layout.coverSide
                )
                radius = layout.coverSide * 0.78 * CGFloat(jitter.scale)
            } else {
                let anchor = anchors[(index - 1) % anchors.count]
                center = CGPoint(
                    x: (anchor.x + CGFloat(jitter.dx)) * canvas.width,
                    y: (anchor.y + CGFloat(jitter.dy)) * canvas.height
                )
                radius = long * style.radius * CGFloat(jitter.scale)
            }
            result.append(ImmersiveWatercolorPoolPlacement(
                center: center,
                radius: radius,
                usesSecondary: style.usesSecondary,
                hue: style.hue,
                lift: style.lift,
                opacity: style.opacity,
                rotation: jitter.rotation,
                phase: jitter.phase,
                drift: long * 0.012
            ))
        }
        return result
    }

    /// 涂鸦的落点：围着封面一圈，竖屏多在两侧，横屏和大屏避开文字那一侧；挤出画布的收回来。
    func doodleSlots(
        for layout: ImmersiveWatercolorStoryLayout,
        in region: CGRect,
        canvas: CGSize
    ) -> [ImmersiveWatercolorDoodleSlot] {
        let angles: [Double] = layout.isStacked
            ? [200, -20, 160, 20, 232, -52, 140, 40]
            : [205, 250, 155, 290, 120, 228, 270, 140]
        let side = Double(layout.coverSide)
        let margin = Double(layout.doodleSize) * 0.7
        let count = min(angles.count, doodleTurns.count, doodleReach.count, doodleSpins.count, doodleKinds.count)
        var slots: [ImmersiveWatercolorDoodleSlot] = []
        for index in 0..<count {
            let radians = (angles[index] + doodleTurns[index]) * Double.pi / 180
            let distance = side * doodleReach[index]
            let rawX = Double(layout.coverCenter.x) + cos(radians) * distance
            let rawY = Double(layout.coverCenter.y) + sin(radians) * distance
            let x = min(max(rawX, margin), Double(canvas.width) - margin)
            let y = min(max(rawY, margin), Double(canvas.height) - margin)
            slots.append(ImmersiveWatercolorDoodleSlot(
                point: CGPoint(x: x - Double(region.minX), y: y - Double(region.minY)),
                turn: doodleSpins[index],
                kind: doodleKinds[index]
            ))
        }
        return slots
    }
}

/// 五团水彩各自的颜色和浓淡：主色垫在封面后，一团深一点的第二色，其余是主色的邻近色、提亮一些。
struct ImmersiveWatercolorPoolStyle {
    let usesSecondary: Bool
    let hue: Double
    let lift: Double
    let opacity: Double
    /// 长边的比例（第一团按封面算，不用这个）。
    let radius: CGFloat

    static let all: [ImmersiveWatercolorPoolStyle] = [
        ImmersiveWatercolorPoolStyle(usesSecondary: false, hue: 0, lift: 0, opacity: 0.40, radius: 0),
        ImmersiveWatercolorPoolStyle(usesSecondary: true, hue: 0, lift: 0.10, opacity: 0.24, radius: 0.26),
        ImmersiveWatercolorPoolStyle(usesSecondary: false, hue: 32, lift: 0.12, opacity: 0.34, radius: 0.30),
        ImmersiveWatercolorPoolStyle(usesSecondary: false, hue: -38, lift: 0.10, opacity: 0.30, radius: 0.32),
        ImmersiveWatercolorPoolStyle(usesSecondary: false, hue: 72, lift: 0.18, opacity: 0.24, radius: 0.20),
    ]
}

// MARK: - 状态：鼓点、弹跳与涂鸦

struct ImmersiveWatercolorDoodle {
    let serial: Int
    let birth: TimeInterval
    let strength: Double
}

/// 这一帧手绘层要画的东西：用哪一种墨线、封面压扁拉长多少、往上跳多少（封面边长的比例）、哪些涂鸦还在。
struct ImmersiveWatercolorStoryFrame {
    var boil = 0
    var stretch = CGSize(width: 1, height: 1)
    var hop: CGFloat = 0
    var doodles: [ImmersiveWatercolorDoodle] = []
    var time: TimeInterval = 0
}

/// 手绘层的宿主：换歌时重算一份 `ImmersiveWatercolorStoryPlan`；逐帧把频谱喂给鼓点检测，鼓点上让封面
/// 先压扁再弹起、强拍上冒一个涂鸦。读不到频谱时封面只轻轻呼吸，涂鸦隔一阵冒一个。
@MainActor
final class ImmersiveWatercolorStoryModel {
    nonisolated static let doodleLife: TimeInterval = 1.8
    nonisolated static let maximumDoodles = 6

    private var tracker = ImmersiveBeatTracker()
    private var bounceStart = -Double.infinity
    private var bounceStrength = 0.0
    private var lastBeat = -Double.infinity
    private var lastDoodle = -Double.infinity
    private var doodles: [ImmersiveWatercolorDoodle] = []
    private var serial = 0
    private var planKey: String?
    private var cachedPlan: ImmersiveWatercolorStoryPlan?

    func plan(for songKey: String) -> ImmersiveWatercolorStoryPlan {
        if let cachedPlan, planKey == songKey { return cachedPlan }
        let plan = ImmersiveWatercolorStoryPlan(songKey: songKey)
        cachedPlan = plan
        planKey = songKey
        doodles.removeAll()
        return plan
    }

    func frame(time: TimeInterval, levels: [CGFloat], animates: Bool) -> ImmersiveWatercolorStoryFrame {
        guard animates else {
            // 停着（暂停、减弱动态效果、省电）：墨线停在第一笔，封面不弹，涂鸦收起。
            doodles.removeAll()
            return ImmersiveWatercolorStoryFrame(time: time)
        }
        let features = tracker.update(levels: levels.map { Double($0) }, at: time)
        if features.beat > 0.18 {
            bounceStart = time
            bounceStrength = min(max(features.beat, 0.35), 1)
            lastBeat = time
            if features.beat > 0.45, time - lastDoodle > 0.5 {
                spawnDoodle(at: time, strength: features.beat)
            }
        }
        // 没有频谱、或者这一段没有鼓：隔一阵冒一个，画面不至于停住。
        if time - lastBeat > 4, time - lastDoodle > 2.6 {
            spawnDoodle(at: time, strength: 0.55)
        }
        doodles.removeAll { time - $0.birth > Self.doodleLife || time < $0.birth }

        var squash = 0.0
        var hop = 0.0
        let since = time - bounceStart
        if since >= 0, since < 1.2 {
            // 落地先压扁，再拉长弹起，来回几下停住。
            let envelope = exp(-since * 6.5) * bounceStrength
            let wave = cos(since * 2 * Double.pi * 3.0)
            squash = -0.07 * envelope * wave
            hop = 0.028 * envelope * max(0, -wave)
        }
        let breath = sin(time * 2 * Double.pi / 4.6) * 0.012
        let stretch = CGSize(
            width: CGFloat(1 - squash * 0.6 - breath * 0.5),
            height: CGFloat(1 + squash + breath)
        )
        let boil = Int((time * 12).rounded(.down)) % ImmersiveWatercolorStoryPlan.boilVariants
        return ImmersiveWatercolorStoryFrame(
            boil: max(boil, 0),
            stretch: stretch,
            hop: CGFloat(hop),
            doodles: doodles,
            time: time
        )
    }

    private func spawnDoodle(at time: TimeInterval, strength: Double) {
        lastDoodle = time
        serial += 1
        doodles.append(ImmersiveWatercolorDoodle(serial: serial, birth: time, strength: min(max(strength, 0), 1)))
        if doodles.count > Self.maximumDoodles {
            doodles.removeFirst(doodles.count - Self.maximumDoodles)
        }
    }
}

// MARK: - 纸

/// 暖色纸面：底色带一点封面色，平铺一张先画好的纸纹（细密的明暗加几根纤维），正片叠底压上去。
struct ImmersiveWatercolorPaper: View {
    let palette: ImmersiveArtworkPalette

    var body: some View {
        ZStack {
            ImmersiveWatercolorInk.paper
            palette.primary.opacity(0.08)
                .blendMode(.multiply)
            if let texture = ImmersiveWatercolorPaperTexture.image {
                texture
                    .resizable(resizingMode: .tile)
                    .blendMode(.multiply)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 纸纹只生成一次：256 像素见方，逐像素一点明暗，再画上一百多根短纤维；跨边的纤维在对面接着画，
/// 平铺看不出接缝。
enum ImmersiveWatercolorPaperTexture {
    static let image: Image? = make()

    private static func make() -> Image? {
        let side = 256
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        var random = ImmersiveRandom(seed: 0x9A9E_5EED_F1B3_0001)
        if let data = context.data {
            let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)
            for index in 0..<(side * side) {
                let value = UInt8(236 + Int(random.unit() * 19))
                pixels[index * 4] = value
                pixels[index * 4 + 1] = value
                pixels[index * 4 + 2] = value
                pixels[index * 4 + 3] = 255
            }
        }
        let extent = Double(side)
        context.setLineCap(.round)
        for _ in 0..<170 {
            let startX = random.unit() * extent
            let startY = random.unit() * extent
            let angle = random.unit() * 2 * Double.pi
            let length = 6 + random.unit() * 22
            let bend = random.centered() * 3
            let gray = 0.74 + random.unit() * 0.16
            context.setStrokeColor(CGColor(gray: CGFloat(gray), alpha: 0.5))
            context.setLineWidth(CGFloat(0.4 + random.unit() * 0.8))
            let endX = startX + cos(angle) * length
            let endY = startY + sin(angle) * length
            let controlX = (startX + endX) / 2 - sin(angle) * bend
            let controlY = (startY + endY) / 2 + cos(angle) * bend
            // 九宫格各画一遍：伸出边的那一截落到对面。
            for column in -1...1 {
                for row in -1...1 {
                    let dx = Double(column) * extent
                    let dy = Double(row) * extent
                    context.move(to: CGPoint(x: startX + dx, y: startY + dy))
                    context.addQuadCurve(
                        to: CGPoint(x: endX + dx, y: endY + dy),
                        control: CGPoint(x: controlX + dx, y: controlY + dy)
                    )
                    context.strokePath()
                }
            }
        }
        // 几粒深一点的纸屑。
        for _ in 0..<60 {
            let radius = CGFloat(0.4 + random.unit() * 0.7)
            let x = CGFloat(random.unit() * extent)
            let y = CGFloat(random.unit() * extent)
            context.setFillColor(CGColor(gray: CGFloat(0.62 + random.unit() * 0.2), alpha: 0.6))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        guard let image = context.makeImage() else { return nil }
        return Image(decorative: image, scale: 2)
    }
}

// MARK: - 水彩

/// 一团水彩的蒙版（黑色，浓淡在透明度里）。
struct ImmersiveWatercolorMask: @unchecked Sendable {
    let image: CGImage
}

struct ImmersiveWatercolorWashMasks {
    let key: String
    let masks: [ImmersiveWatercolorMask]
}

/// 最近两首歌的水彩蒙版：设置页预览、效果抽屉和全屏页同一首歌只画一次。
@MainActor
enum ImmersiveWatercolorWashCache {
    private static var entries: [ImmersiveWatercolorWashMasks] = []

    static func masks(for key: String) -> ImmersiveWatercolorWashMasks? {
        entries.first { $0.key == key }
    }

    static func store(_ value: ImmersiveWatercolorWashMasks) {
        entries.removeAll { $0.key == value.key }
        entries.insert(value, at: 0)
        if entries.count > 2 {
            entries.removeLast(entries.count - 2)
        }
    }

    /// 正在后台画的那几首。抽屉缩略图、转轮那一面和全屏页同时要同一首时共用一次,不各画一份。
    private static var inFlight: [String: Task<[ImmersiveWatercolorMask], Never>] = [:]

    /// 有缓存直接给;正在画就等那一次;都没有才起一次后台绘制。画完先存下,调用方被取消也不白画。
    static func paintedMasks(for key: String) async -> ImmersiveWatercolorWashMasks {
        if let cached = masks(for: key) { return cached }
        let task: Task<[ImmersiveWatercolorMask], Never>
        if let running = inFlight[key] {
            task = running
        } else {
            let seed = ImmersiveRandom.seed(for: key)
            let count = ImmersiveWatercolorStoryPlan.poolCount
            task = Task.detached(priority: .userInitiated) {
                ImmersiveWatercolorWashPainter.paint(seed: seed, count: count)
            }
            inFlight[key] = task
        }
        let masks = await task.value
        inFlight[key] = nil
        if let cached = Self.masks(for: key) { return cached }
        let value = ImmersiveWatercolorWashMasks(key: key, masks: masks)
        store(value)
        return value
    }
}

/// 几团大水彩。形状在后台按歌名画成蒙版（`ImmersiveWatercolorWashPainter`），这里上色（主色、第二色，
/// 邻近色用色相旋转、淡的再提亮），正片叠底叠在纸上，慢慢漂、轻轻胀缩；换歌时新的一套淡入。
struct ImmersiveWatercolorWashes: View {
    @Environment(\.immersiveFrameRate) private var frameRate
    @Environment(\.immersiveMotionIntensity) private var motion

    let songKey: String
    let placements: [ImmersiveWatercolorPoolPlacement]
    let palette: ImmersiveArtworkPalette
    let isAnimating: Bool

    @State private var painted: ImmersiveWatercolorWashMasks?

    var body: some View {
        TimelineView(.animation(
            minimumInterval: frameRate.minimumInterval(base: 1.0 / 12),
            paused: !isAnimating || painted == nil
        )) { context in
            let time = context.date.timeIntervalSinceReferenceDate * motion.speed
            ZStack(alignment: .topLeading) {
                if let painted {
                    pools(painted.masks, time: time)
                        .id(painted.key)
                        .transition(.opacity)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: songKey) {
            await paint(for: songKey)
        }
    }

    private func pools(_ masks: [ImmersiveWatercolorMask], time: TimeInterval) -> some View {
        let count = min(masks.count, placements.count)
        return ZStack(alignment: .topLeading) {
            ForEach(0..<count, id: \.self) { index in
                pool(masks[index], placement: placements[index], time: time)
            }
        }
    }

    private func pool(
        _ mask: ImmersiveWatercolorMask,
        placement: ImmersiveWatercolorPoolPlacement,
        time: TimeInterval
    ) -> some View {
        let phase = placement.phase
        let wobble = sin(time * 0.11 + phase)
        let driftX = CGFloat(sin(time * 0.07 + phase)) * placement.drift
        let driftY = CGFloat(cos(time * 0.05 + phase * 1.3)) * placement.drift
        let side = placement.radius * CGFloat(ImmersiveWatercolorWashPainter.extent * 2)
        let tint = placement.usesSecondary ? palette.secondary : palette.primary
        return Image(decorative: mask.image, scale: 1)
            .resizable()
            .renderingMode(.template)
            .interpolation(.medium)
            .foregroundStyle(tint)
            .hueRotation(.degrees(placement.hue))
            .brightness(placement.lift)
            .frame(width: side, height: side)
            .rotationEffect(.degrees(placement.rotation + wobble * 2))
            .scaleEffect(1 + CGFloat(wobble) * 0.025)
            .opacity(placement.opacity)
            .blendMode(.multiply)
            .position(x: placement.center.x + driftX, y: placement.center.y + driftY)
    }

    private func paint(for key: String) async {
        if let cached = ImmersiveWatercolorWashCache.masks(for: key) {
            painted = cached
            return
        }
        // 换歌把这次任务取消了也照样画完存下：再切回这首歌不用重画。
        let value = await ImmersiveWatercolorWashCache.paintedMasks(for: key)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.8)) {
            painted = value
        }
    }
}

/// 把一团水彩画成蒙版：一个不规则多边形反复做中点位移，叠几十层每层再各自变形一点、透明度很低的填充
/// （中间层层叠满、边上只有几层，边缘自然晕开），隔几层描一圈淡边当积色，最后点上颗粒。
enum ImmersiveWatercolorWashPainter {
    /// 水彩本来就是软的，放大显示看不出；五张蒙版每张不到 1 MB。
    static let pixelSide = 448
    /// 形状按半径 1 生成，蒙版铺到 ±1.6。
    static let extent = 1.6

    static func paint(seed: UInt64, count: Int) -> [ImmersiveWatercolorMask] {
        var masks: [ImmersiveWatercolorMask] = []
        for index in 0..<count {
            var random = ImmersiveRandom(seed: seed &+ UInt64(index + 1) &* 0x9E37_79B9_7F4A_7C15)
            if let mask = paintPool(random: &random) {
                masks.append(mask)
            }
        }
        return masks
    }

    private static func paintPool(random: inout ImmersiveRandom) -> ImmersiveWatercolorMask? {
        let side = pixelSide
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let scale = Double(side) / (extent * 2)
        let center = Double(side) / 2
        let black = CGColor(gray: 0, alpha: 1)
        context.setFillColor(black)
        context.setStrokeColor(black)
        context.setLineJoin(.round)

        let corners = 10
        var base: [CGPoint] = []
        var weights: [Double] = []
        for index in 0..<corners {
            let angle = Double(index) / Double(corners) * 2 * Double.pi
            let radius = 0.82 + random.unit() * 0.22
            base.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
            weights.append(0.18 + random.unit() * 0.32)
        }
        let shaped = ImmersiveWatercolorGeometry.deform(
            ImmersiveWatercolorPolygon(points: base, weights: weights),
            depth: 3,
            random: &random
        )

        // 三叠，每叠十二层：每叠先从同一个底形各变出一个样子，层层再细变。
        for _ in 0..<3 {
            let stack = ImmersiveWatercolorGeometry.deform(shaped, depth: 1, random: &random)
            for layer in 0..<12 {
                let wet = ImmersiveWatercolorGeometry.deform(stack, depth: 2, random: &random)
                let path = CGMutablePath()
                path.addLines(between: wet.points.map { point in
                    CGPoint(x: center + Double(point.x) * scale, y: center + Double(point.y) * scale)
                })
                path.closeSubpath()
                context.setAlpha(0.05)
                context.addPath(path)
                context.fillPath()
                if layer % 4 == 0 {
                    // 颜料在水边积下的那一圈深色。
                    context.setAlpha(0.07)
                    context.setLineWidth(1.2)
                    context.addPath(path)
                    context.strokePath()
                }
            }
        }

        // 颗粒：先抠掉一些细点（颜料沉进纸纹里露出的白），再点几百个聚起来的小点。
        context.setBlendMode(.destinationOut)
        for _ in 0..<2200 {
            let angle = random.unit() * 2 * Double.pi
            let distance = random.unit().squareRoot() * 1.35
            let radius = CGFloat(0.5 + random.unit() * 1.3)
            let x = CGFloat(center + cos(angle) * distance * scale)
            let y = CGFloat(center + sin(angle) * distance * scale)
            context.setAlpha(CGFloat(0.18 + random.unit() * 0.3))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        context.setBlendMode(.normal)
        for _ in 0..<900 {
            let angle = random.unit() * 2 * Double.pi
            let distance = random.unit().squareRoot() * 1.1
            let radius = CGFloat(0.6 + random.unit() * 1.0)
            let x = CGFloat(center + cos(angle) * distance * scale)
            let y = CGFloat(center + sin(angle) * distance * scale)
            context.setAlpha(CGFloat(0.06 + random.unit() * 0.08))
            context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
        }
        guard let image = context.makeImage() else { return nil }
        return ImmersiveWatercolorMask(image: image)
    }
}

// MARK: - 几何

/// 带「水性」的多边形：每个顶点一个权重，中点位移时这一段推多远按它。
struct ImmersiveWatercolorPolygon {
    var points: [CGPoint]
    var weights: [Double]
}

enum ImmersiveWatercolorGeometry {
    /// 中点位移：每条边中间插一个点，往随机方向推出去，推多远按边长和两端的权重；新点的权重取两端平均再抖一点。
    /// 做 `depth` 轮，点数每轮翻倍。
    static func deform(
        _ polygon: ImmersiveWatercolorPolygon,
        depth: Int,
        random: inout ImmersiveRandom
    ) -> ImmersiveWatercolorPolygon {
        var points = polygon.points
        var weights = polygon.weights
        guard points.count > 2, points.count == weights.count else { return polygon }
        for _ in 0..<max(depth, 0) {
            let count = points.count
            var nextPoints: [CGPoint] = []
            var nextWeights: [Double] = []
            nextPoints.reserveCapacity(count * 2)
            nextWeights.reserveCapacity(count * 2)
            for index in 0..<count {
                let a = points[index]
                let b = points[(index + 1) % count]
                let wa = weights[index]
                let wb = weights[(index + 1) % count]
                let dx = Double(b.x - a.x)
                let dy = Double(b.y - a.y)
                let length = (dx * dx + dy * dy).squareRoot()
                let spread = length * (wa + wb) * 0.25
                let mid = CGPoint(
                    x: Double(a.x + b.x) / 2 + random.centered() * spread,
                    y: Double(a.y + b.y) / 2 + random.centered() * spread
                )
                nextPoints.append(a)
                nextWeights.append(wa)
                nextPoints.append(mid)
                nextWeights.append((wa + wb) * 0.5 * (0.85 + random.unit() * 0.3))
            }
            points = nextPoints
            weights = nextWeights
        }
        return ImmersiveWatercolorPolygon(points: points, weights: weights)
    }

    /// 封面的毛边：单位正方形里的一圈圆角方块，边上两种起伏——低频的手裁歪斜、高频的纸边毛刺。
    /// 整圈往里收了一点，毛边往外鼓时也不出封面的范围。
    static func deckle(random: inout ImmersiveRandom) -> [CGPoint] {
        let count = 96
        let corner = 0.07
        let phaseA = random.unit() * 2 * Double.pi
        let phaseB = random.unit() * 2 * Double.pi
        var points: [CGPoint] = []
        points.reserveCapacity(count)
        for index in 0..<count {
            let fraction = Double(index) / Double(count)
            let edge = roundedSquare(at: fraction, corner: corner)
            let turn = fraction * 2 * Double.pi
            let slant = sin(turn * 3 + phaseA) * 0.005
            let ripple = sin(turn * 7 + phaseB) * 0.003
            let push = slant + ripple + random.centered() * 0.0028
            let x = 0.015 + (Double(edge.point.x) + Double(edge.normal.dx) * push) * 0.97
            let y = 0.015 + (Double(edge.point.y) + Double(edge.normal.dy) * push) * 0.97
            points.append(CGPoint(x: x, y: y))
        }
        return points
    }

    /// 同一圈轮廓重描一遍：每个点抖一点，整圈再错开一点，像手又描了一笔。
    static func redraw(_ points: [CGPoint], amount: Double, random: inout ImmersiveRandom) -> [CGPoint] {
        let shiftX = random.centered() * amount * 0.6
        let shiftY = random.centered() * amount * 0.6
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            result.append(CGPoint(
                x: Double(point.x) + shiftX + random.centered() * amount,
                y: Double(point.y) + shiftY + random.centered() * amount
            ))
        }
        return result
    }

    /// 单位正方形里圆角方块的一圈，按周长等分取点：`fraction` 0 从上边左端开始顺时针走一圈。
    /// 返回那一点和朝外的法线。
    static func roundedSquare(at fraction: Double, corner: Double) -> (point: CGPoint, normal: CGVector) {
        let straight = 1 - 2 * corner
        let arc = Double.pi * corner / 2
        let sideLength = straight + arc
        var distance = (fraction - fraction.rounded(.down)) * sideLength * 4
        let edge = min(Int(distance / sideLength), 3)
        distance -= Double(edge) * sideLength
        var x: Double
        var y: Double
        var nx: Double
        var ny: Double
        // 先按「上边加右上角」这一段算，再按第几段绕中心转 90°。
        if distance < straight {
            x = corner + distance
            y = 0
            nx = 0
            ny = -1
        } else {
            let angle = (distance - straight) / corner
            nx = sin(angle)
            ny = -cos(angle)
            x = 1 - corner + corner * nx
            y = corner + corner * ny
        }
        for _ in 0..<edge {
            (x, y) = (1 - y, x)
            (nx, ny) = (-ny, nx)
        }
        return (CGPoint(x: x, y: y), CGVector(dx: nx, dy: ny))
    }

    /// 水彩带：一条长方形先变形成底，再叠十层各自再变一点，都落在带子画布里（`bandCanvasScale`）。
    static func bandLayers(random: inout ImmersiveRandom) -> [[CGPoint]] {
        let scale = ImmersiveWatercolorStoryPlan.bandCanvasScale
        let insetX = Double((scale.width - 1) / scale.width) / 2
        let insetY = Double((scale.height - 1) / scale.height) / 2
        let left = insetX
        let right = 1 - insetX
        let top = insetY
        let bottom = 1 - insetY
        let rectangle = [
            CGPoint(x: left, y: top), CGPoint(x: (left + right) / 2, y: top),
            CGPoint(x: right, y: top), CGPoint(x: right, y: (top + bottom) / 2),
            CGPoint(x: right, y: bottom), CGPoint(x: (left + right) / 2, y: bottom),
            CGPoint(x: left, y: bottom), CGPoint(x: left, y: (top + bottom) / 2),
        ]
        var weights: [Double] = []
        for _ in rectangle {
            weights.append(0.10 + random.unit() * 0.12)
        }
        let base = deform(ImmersiveWatercolorPolygon(points: rectangle, weights: weights), depth: 2, random: &random)
        var layers: [[CGPoint]] = []
        for _ in 0..<10 {
            let layer = deform(base, depth: 2, random: &random)
            layers.append(layer.points.map { point in
                CGPoint(x: min(max(Double(point.x), 0.01), 0.99), y: min(max(Double(point.y), 0.01), 0.99))
            })
        }
        return layers
    }

    /// 闭合的平滑轮廓：相邻两点的中点连成二次曲线，控制点是原来的顶点。`points` 在单位正方形里，铺进 `rect`。
    static func smoothClosedPath(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        let count = points.count
        guard count > 2 else { return path }
        func place(_ point: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        }
        func middle(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: place(middle(points[count - 1], points[0])))
        for index in 0..<count {
            let control = points[index]
            let end = middle(points[index], points[(index + 1) % count])
            path.addQuadCurve(to: place(end), control: place(control))
        }
        path.closeSubpath()
        return path
    }

    /// 闭合折线，单位坐标铺进 `rect`。
    static func closedPolygon(_ points: [CGPoint], in rect: CGRect) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        path.addLines(points.map { point in
            CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
        })
        path.closeSubpath()
        return path
    }
}

/// 封面毛边的形状（单位正方形里的轮廓）。
struct ImmersiveWatercolorOutlineShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        ImmersiveWatercolorGeometry.smoothClosedPath(points, in: rect)
    }
}

// MARK: - 封面

/// 封面画成贴在纸上的一幅画：毛边剪裁、叠一层纸纹和一层淡淡的封面色，底下错开一块淡彩当影子，
/// 外面一圈墨线按 `boil` 换着描。
struct ImmersiveWatercolorCover<Artwork: View>: View {
    let side: CGFloat
    let plan: ImmersiveWatercolorStoryPlan
    let palette: ImmersiveArtworkPalette
    let boil: Int
    let artwork: (CGFloat) -> Artwork

    var body: some View {
        let clip = ImmersiveWatercolorOutlineShape(points: plan.coverClip)
        ZStack {
            // 影子是一块错开的淡彩，不用模糊。
            clip
                .fill(palette.secondary.opacity(0.26))
                .frame(width: side, height: side)
                .offset(x: side * 0.035, y: side * 0.045)
                .blendMode(.multiply)

            artwork(side)
                .frame(width: side, height: side)
                .overlay {
                    if let texture = ImmersiveWatercolorPaperTexture.image {
                        texture
                            .resizable(resizingMode: .tile)
                            .blendMode(.multiply)
                    }
                }
                .overlay {
                    palette.primary.opacity(0.08)
                        .blendMode(.multiply)
                }
                .clipShape(clip)

            ImmersiveWatercolorCoverOutline(outlines: plan.coverOutlines, boil: boil)
                .frame(width: side * 1.1, height: side * 1.1)
        }
        .frame(width: side * 1.1, height: side * 1.1)
    }
}

/// 封面外那圈墨线：一笔主线加一笔淡淡的重描，两笔用不同的抖法。画布比封面大一圈，线不会被切掉。
struct ImmersiveWatercolorCoverOutline: View {
    let outlines: [[CGPoint]]
    let boil: Int

    var body: some View {
        Canvas { context, size in
            guard !outlines.isEmpty else { return }
            let inner = size.width / 1.1
            let rect = CGRect(
                x: (size.width - inner) / 2,
                y: (size.height - inner) / 2,
                width: inner,
                height: inner
            )
            let count = outlines.count
            let main = outlines[((boil % count) + count) % count]
            let echo = outlines[(((boil + 1) % count) + count) % count]
            let width = max(1.4, inner * 0.011)
            context.stroke(
                ImmersiveWatercolorGeometry.smoothClosedPath(main, in: rect),
                with: .color(ImmersiveWatercolorInk.ink.opacity(0.86)),
                style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
            )
            context.stroke(
                ImmersiveWatercolorGeometry.smoothClosedPath(echo, in: rect.insetBy(dx: -inner * 0.006, dy: -inner * 0.006)),
                with: .color(ImmersiveWatercolorInk.ink.opacity(0.26)),
                style: StrokeStyle(lineWidth: width * 0.55, lineCap: .round, lineJoin: .round)
            )
        }
        .allowsHitTesting(false)
    }
}

// MARK: - 水彩带

/// 歌词后面那条水彩：十层歪歪的长方形，每层很淡，叠出中间浓、边上晕开的一条。
struct ImmersiveWatercolorBandWash: View {
    let layers: [[CGPoint]]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size)
            for (index, layer) in layers.enumerated() {
                let path = ImmersiveWatercolorGeometry.closedPolygon(layer, in: rect)
                context.fill(path, with: .color(tint.opacity(0.05)))
                if index % 3 == 0 {
                    context.stroke(path, with: .color(tint.opacity(0.06)), lineWidth: 1)
                }
            }
        }
        .blendMode(.multiply)
        .allowsHitTesting(false)
    }
}

// MARK: - 涂鸦

/// 一个涂鸦的笔画（单位坐标，中心在原点）：描的线和填的块。
struct ImmersiveWatercolorGlyph {
    var strokes: [[CGPoint]]
    var fills: [[CGPoint]]
}

/// 四种小涂鸦：音符、星星、闪光十字、小漩涡。每种先抖出几种笔迹，和墨线一样按帧轮着用。
enum ImmersiveWatercolorGlyphs {
    static let kindCount = 4
    /// [种类][抖法]
    static let all: [[ImmersiveWatercolorGlyph]] = make()

    private static func make() -> [[ImmersiveWatercolorGlyph]] {
        var random = ImmersiveRandom(seed: 0xD00D_1E5A_7C3B_0042)
        let shapes = [note(), star(), sparkle(), spiral()]
        var result: [[ImmersiveWatercolorGlyph]] = []
        for shape in shapes {
            var variants: [ImmersiveWatercolorGlyph] = []
            for _ in 0..<ImmersiveWatercolorStoryPlan.boilVariants {
                var strokes: [[CGPoint]] = []
                for stroke in shape.strokes {
                    strokes.append(jittered(stroke, random: &random))
                }
                var fills: [[CGPoint]] = []
                for fill in shape.fills {
                    fills.append(jittered(fill, random: &random))
                }
                variants.append(ImmersiveWatercolorGlyph(strokes: strokes, fills: fills))
            }
            result.append(variants)
        }
        return result
    }

    private static func jittered(_ points: [CGPoint], random: inout ImmersiveRandom) -> [CGPoint] {
        var result: [CGPoint] = []
        result.reserveCapacity(points.count)
        for point in points {
            result.append(CGPoint(
                x: Double(point.x) + random.centered() * 0.018,
                y: Double(point.y) + random.centered() * 0.018
            ))
        }
        return result
    }

    /// 八分音符：斜着的实心符头、符干和一道符尾。
    private static func note() -> ImmersiveWatercolorGlyph {
        var head: [CGPoint] = []
        let tilt = -0.35
        for index in 0..<14 {
            let angle = Double(index) / 14 * 2 * Double.pi
            let x = cos(angle) * 0.17
            let y = sin(angle) * 0.12
            head.append(CGPoint(
                x: -0.13 + x * cos(tilt) - y * sin(tilt),
                y: 0.27 + x * sin(tilt) + y * cos(tilt)
            ))
        }
        let stem = [CGPoint(x: 0.03, y: 0.24), CGPoint(x: 0.035, y: -0.08), CGPoint(x: 0.03, y: -0.42)]
        var flag: [CGPoint] = []
        for index in 0...8 {
            let t = Double(index) / 8
            let u = 1 - t
            // 二次贝塞尔：从符干顶端甩出去再落下来。
            let start = u * u
            let pull = 2 * u * t
            let end = t * t
            let x: Double = start * 0.03 + pull * 0.36 + end * 0.24
            let y: Double = start * -0.42 + pull * -0.30 + end * -0.02
            flag.append(CGPoint(x: x, y: y))
        }
        return ImmersiveWatercolorGlyph(strokes: [stem, flag], fills: [head])
    }

    /// 五角星。
    private static func star() -> ImmersiveWatercolorGlyph {
        var points: [CGPoint] = []
        for index in 0..<10 {
            let angle = -Double.pi / 2 + Double(index) * Double.pi / 5
            let radius = index % 2 == 0 ? 0.5 : 0.21
            points.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        }
        if let first = points.first { points.append(first) }
        return ImmersiveWatercolorGlyph(strokes: [points], fills: [points])
    }

    /// 四角的闪光十字。
    private static func sparkle() -> ImmersiveWatercolorGlyph {
        let points = [
            CGPoint(x: 0, y: -0.5), CGPoint(x: 0.09, y: -0.09), CGPoint(x: 0.5, y: 0), CGPoint(x: 0.09, y: 0.09),
            CGPoint(x: 0, y: 0.5), CGPoint(x: -0.09, y: 0.09), CGPoint(x: -0.5, y: 0), CGPoint(x: -0.09, y: -0.09),
            CGPoint(x: 0, y: -0.5),
        ]
        return ImmersiveWatercolorGlyph(strokes: [points], fills: [points])
    }

    /// 由内往外绕两圈多的小漩涡。
    private static func spiral() -> ImmersiveWatercolorGlyph {
        var points: [CGPoint] = []
        let turns = 4.2 * Double.pi
        for index in 0...44 {
            let angle = Double(index) / 44 * turns
            let radius = 0.03 + 0.44 * angle / turns
            points.append(CGPoint(x: cos(angle) * radius, y: sin(angle) * radius))
        }
        return ImmersiveWatercolorGlyph(strokes: [points], fills: [])
    }
}

/// 封面周围冒出来的小涂鸦：落点按出现的先后轮着用，带一点回弹地冒出来，往上飘一点再淡掉。
struct ImmersiveWatercolorDoodles: View {
    let doodles: [ImmersiveWatercolorDoodle]
    let time: TimeInterval
    let boil: Int
    let slots: [ImmersiveWatercolorDoodleSlot]
    let size: CGFloat
    let accent: Color

    var body: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            guard !slots.isEmpty else { return }
            for doodle in doodles {
                ImmersiveWatercolorDoodlePainter.draw(
                    doodle,
                    slot: slots[doodle.serial % slots.count],
                    time: time,
                    boil: boil,
                    size: size,
                    accent: accent,
                    in: &context
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

enum ImmersiveWatercolorDoodlePainter {
    static func draw(
        _ doodle: ImmersiveWatercolorDoodle,
        slot: ImmersiveWatercolorDoodleSlot,
        time: TimeInterval,
        boil: Int,
        size: CGFloat,
        accent: Color,
        in context: inout GraphicsContext
    ) {
        let glyphs = ImmersiveWatercolorGlyphs.all
        guard !glyphs.isEmpty else { return }
        let variants = glyphs[((slot.kind % glyphs.count) + glyphs.count) % glyphs.count]
        guard !variants.isEmpty else { return }
        let glyph = variants[(((boil + doodle.serial) % variants.count) + variants.count) % variants.count]

        let life = ImmersiveWatercolorStoryModel.doodleLife
        let age = time - doodle.birth
        guard age >= 0, age <= life else { return }
        let pop = age < 0.28 ? easeOutBack(age / 0.28) : 1
        let fadeIn = min(age / 0.06, 1)
        let fadeOut = min(max((life - age) / 0.6, 0), 1)
        let opacity = fadeIn * fadeOut
        guard opacity > 0.01, pop > 0.01 else { return }

        let extent = Double(size) * (0.8 + 0.4 * doodle.strength) * pop
        let radians = (slot.turn + sin(age * 5) * 4) * Double.pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let centerX = Double(slot.point.x)
        let centerY = Double(slot.point.y) - Double(size) * 0.6 * age / life
        func place(_ point: CGPoint) -> CGPoint {
            let x = Double(point.x) * extent
            let y = Double(point.y) * extent
            return CGPoint(x: centerX + x * cosine - y * sine, y: centerY + x * sine + y * cosine)
        }

        var layer = context
        layer.opacity = opacity
        let lineWidth = max(1.2, Double(size) * 0.07)
        let ink = ImmersiveWatercolorInk.ink
        for fill in glyph.fills {
            var path = Path()
            path.addLines(fill.map(place))
            path.closeSubpath()
            // 音符的符头填墨，星星和闪光填一层淡淡的封面色。
            let shading: GraphicsContext.Shading = glyph.strokes.count > 1
                ? .color(ink.opacity(0.9))
                : .color(accent.opacity(0.55))
            layer.fill(path, with: shading)
        }
        for stroke in glyph.strokes {
            var path = Path()
            path.addLines(stroke.map(place))
            layer.stroke(
                path,
                with: .color(ink.opacity(0.88)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// 冒出来时先冲过头一点再落回原大小。
    private static func easeOutBack(_ value: Double) -> Double {
        let t = min(max(value, 0), 1)
        let overshoot = 1.70158
        let shifted = t - 1
        return 1 + (overshoot + 1) * shifted * shifted * shifted + overshoot * shifted * shifted
    }
}
