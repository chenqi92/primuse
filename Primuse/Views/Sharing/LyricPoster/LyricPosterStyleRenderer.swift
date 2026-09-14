import SwiftUI
import PrimuseKit

// MARK: - 调色板

/// 海报配色。取自封面主色, 没有封面(或封面无彩度)时退回一套中性夜色,
/// 而不是硬套品牌绿 —— 灰度封面配上品牌色会显得像贴错了图。
struct LyricPosterPalette: Equatable {
    var accent: Color
    var secondary: Color
    var deep: Color
    /// 封面本身偏亮。浅色风格据此决定正文用深色还是浅色。
    var isLight: Bool

    static let fallback = LyricPosterPalette(
        accent: Color(red: 0.42, green: 0.45, blue: 0.72),
        secondary: Color(red: 0.72, green: 0.48, blue: 0.58),
        deep: Color(red: 0.07, green: 0.07, blue: 0.12),
        isLight: false
    )

    /// 复用播放器取色: 同一首歌在沉浸背景和海报上的主色一致。
    static func make(from image: PlatformImage?) -> LyricPosterPalette {
        guard let image, let result = ThemeService.extractDominantColor(from: image) else {
            return .fallback
        }
        return LyricPosterPalette(
            accent: result.accent,
            secondary: result.secondary,
            deep: result.dark,
            isLight: result.luminance > 0.62
        )
    }

    /// 渐变底: 深色风格统一用 主色 → 次色 → 暗部 三段, 避免每个风格各写一套。
    var backdropGradient: LinearGradient {
        LinearGradient(
            colors: [
                accent.opacity(0.92),
                secondary.opacity(0.86),
                deep,
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - 渲染上下文

/// 渲染一帧海报需要的全部输入。
///
/// 是一份快照: 用户在分享面板里继续听歌、切歌, 海报上的内容不跟着变,
/// 因此风格实现不允许回头去读 player / 任何全局状态。
struct LyricPosterRenderContext {
    let content: LyricPosterContent
    let canvas: LyricPosterCanvas
    let palette: LyricPosterPalette
    let artwork: PlatformImage?
    /// 预先用 Core Image 糊好的封面。ImageRenderer 对 SwiftUI `.blur` 的支持
    /// 依平台而异, 背景这种必须糊掉的地方不能赌 —— 清晰封面直接顶到歌词
    /// 后面就没法读了。
    let blurredArtwork: PlatformImage?
    /// 动态海报时间线。静态海报也带着它 —— 静态帧就是时间线末尾那一帧。
    let motion: LyricPosterMotionPlan
    /// 当前帧在时间线上的位置。
    let time: TimeInterval
    /// 动态导出中。静态导出时所有行直接呈现完成态, 不做入场动画。
    let isMotion: Bool
    /// 是否画出译文(用户可关)。版面放不下时 metrics 还会再否决一次。
    let includesTranslation: Bool
    /// 右下角的出处署名。
    let showsCredit: Bool
    /// 歌词的书写方向。风格一律用 leading/trailing 对齐, 因此改这一个值
    /// 就能让阿拉伯语、希伯来语歌词整体翻到右边。
    let layoutDirection: LayoutDirection
    let appName: String

    var size: CGSize {
        CGSize(width: canvas.pixelWidth, height: canvas.pixelHeight)
    }

    var artworkImage: Image? {
        artwork.map { Image(platformImage: $0) }
    }

    var blurredArtworkImage: Image? {
        (blurredArtwork ?? artwork).map { Image(platformImage: $0) }
    }

    var hasArtwork: Bool { artwork != nil }

    /// 歌词可用的字号与宽度。
    ///
    /// `reservedHeight` 是这个风格版面上除歌词以外的固定高度(封面、唱片、
    /// 画格、署名、各段 padding 与 spacing 的总和, 按 1080 宽的设计稿计)。
    /// 歌词的高度配额必须从画布高度里扣掉它们再分 —— 写死成"画布高度的
    /// 百分之多少"的话, 同一个风格换到方形画幅就会被固定元素挤出画布,
    /// 而离屏渲染只会把溢出的部分裁掉。
    func metrics(
        textWidthRatio: Double = LyricPosterLayoutPolicy.defaultTextWidthRatio,
        reservedHeight: Double = 0,
        breathingRatio: Double = 0.10
    ) -> LyricPosterTypeMetrics {
        let canvasHeight = canvas.pixelHeight
        let floor = canvasHeight * 0.16
        let breathing = max(canvasHeight - reservedHeight - canvasHeight * breathingRatio, floor)
        var resolved = LyricPosterLayoutPolicy.metrics(
            for: content,
            canvas: canvas,
            textWidthRatio: textWidthRatio,
            lyricHeightRatio: breathing / canvasHeight
        )
        if resolved.overflows {
            // 上下留白是"好看"而不是"必须"。挤不下的时候先把它让出来,
            // 真的还放不下再让 overflows 立着, 免得版面明明装得下却报警。
            let withoutBreathing = max(canvasHeight - reservedHeight, floor)
            if withoutBreathing > breathing {
                resolved = LyricPosterLayoutPolicy.metrics(
                    for: content,
                    canvas: canvas,
                    textWidthRatio: textWidthRatio,
                    lyricHeightRatio: withoutBreathing / canvasHeight
                )
            }
        }
        if !includesTranslation {
            resolved = LyricPosterTypeMetrics(
                lyricFontSize: resolved.lyricFontSize,
                lyricLineSpacing: resolved.lyricLineSpacing,
                translationFontSize: resolved.translationFontSize,
                titleFontSize: resolved.titleFontSize,
                captionFontSize: resolved.captionFontSize,
                textWidth: resolved.textWidth,
                estimatedHeight: resolved.estimatedHeight,
                hidesTranslation: true,
                overflows: resolved.overflows
            )
        }
        return resolved
    }

    /// 某一行的呈现进度。静态海报恒为 1。
    func reveal(ofLineAt index: Int) -> Double {
        guard isMotion else { return 1 }
        return motion.reveal(ofLineAt: index, at: time)
    }

    /// 整体入场进度 (背景缩放 / 装饰浮入), 0…1。
    var entrance: Double {
        guard isMotion, motion.duration > 0 else { return 1 }
        return min(max(time / motion.duration, 0), 1)
    }

    /// 按画布宽度换算设计稿上的尺寸 —— 1080 宽是基准。
    func scaled(_ value: Double) -> CGFloat {
        CGFloat(value * canvas.pixelWidth / 1080)
    }
}

// MARK: - 风格适配器

/// 内置风格的画幅、排序、是否依赖封面都由 Kit 里的目录策略定义, 渲染实现
/// 只按 id 取回来。id 对不上时给一份保守兜底, 避免因为一次改名就崩。
func builtInPosterDescriptor(
    _ id: LyricPosterStyleID,
    symbol: String,
    order: Int
) -> LyricPosterStyleDescriptor {
    LyricPosterStyleCatalog.descriptor(for: id)
        ?? LyricPosterStyleDescriptor(
            id: id,
            nameKey: "lyric_poster_style_fallback",
            symbolName: symbol,
            order: order
        )
}

/// 一种海报风格。新增风格 = 实现这个协议 + 在注册表里登记一次,
/// 其它地方(选择器、导出、偏好存储)都不需要改。
@MainActor
protocol LyricPosterStyleRendering {
    var descriptor: LyricPosterStyleDescriptor { get }
    /// 这个风格给歌词分到的字号与宽度。单独暴露出来, 分享面板才能在版面
    /// 装不下时提醒用户换画幅 —— 否则只能导出一张被裁的图。
    func metrics(for context: LyricPosterRenderContext) -> LyricPosterTypeMetrics
    /// 画满整块画布。调用方已经把画布尺寸框好, 实现内部不要再加外边距以外的 frame。
    func makeBody(context: LyricPosterRenderContext) -> AnyView
}

/// 可用风格的登记处。内置风格在这里注册; 之后加风格只需要在
/// `registerBuiltInStyles()` 里补一行, 或在别处调用 `register(_:)`。
@MainActor
final class LyricPosterStyleRegistry {
    static let shared = LyricPosterStyleRegistry()

    private var renderersByID: [LyricPosterStyleID: any LyricPosterStyleRendering] = [:]
    private var order: [LyricPosterStyleID] = []

    private init() {
        registerBuiltInStyles()
    }

    func register(_ renderer: any LyricPosterStyleRendering) {
        let id = renderer.descriptor.id
        if renderersByID[id] == nil {
            order.append(id)
        }
        renderersByID[id] = renderer
    }

    func renderer(for id: LyricPosterStyleID) -> (any LyricPosterStyleRendering)? {
        renderersByID[id]
    }

    /// 已注册风格的描述, 按 descriptor.order 排序。目录策略再按封面 /
    /// 动态能力过滤。
    var descriptors: [LyricPosterStyleDescriptor] {
        order
            .compactMap { renderersByID[$0]?.descriptor }
            .sorted { $0.order < $1.order }
    }

    func availableDescriptors(
        hasArtwork: Bool,
        requiresMotion: Bool
    ) -> [LyricPosterStyleDescriptor] {
        LyricPosterStyleCatalog.availableDescriptors(
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
    }

    func resolvedDescriptor(
        preferred: LyricPosterStyleID?,
        hasArtwork: Bool,
        requiresMotion: Bool
    ) -> LyricPosterStyleDescriptor? {
        LyricPosterStyleCatalog.resolvedDescriptor(
            preferred: preferred,
            in: descriptors,
            hasArtwork: hasArtwork,
            requiresMotion: requiresMotion
        )
    }

    private func registerBuiltInStyles() {
        register(AuroraGlassPosterStyle())
        register(GradientQuotePosterStyle())
        register(MagazinePosterStyle())
        register(VinylPosterStyle())
        register(FilmStillPosterStyle())
        register(NeonNightPosterStyle())
        register(PolaroidPosterStyle())
        register(CassettePosterStyle())
    }
}

// MARK: - 共享版式部件

/// 歌词正文。所有风格共用同一套逐行呈现规则, 这样换风格换的是画面,
/// 不是歌词的读法。
struct LyricPosterPassageView: View {
    let context: LyricPosterRenderContext
    let metrics: LyricPosterTypeMetrics
    var alignment: HorizontalAlignment = .leading
    var textAlignment: TextAlignment = .leading
    /// 已唱 / 当前行的颜色。
    var primaryStyle: AnyShapeStyle
    /// 还没到的行。
    var pendingStyle: AnyShapeStyle
    var translationStyle: AnyShapeStyle
    var fontDesign: Font.Design = .rounded
    var fontWeight: Font.Weight = .bold
    var shadow: Color? = nil

    var body: some View {
        VStack(alignment: alignment, spacing: metrics.lyricLineSpacing) {
            ForEach(Array(context.content.lines.enumerated()), id: \.element.id) { index, line in
                let reveal = context.reveal(ofLineAt: index)
                VStack(alignment: alignment, spacing: metrics.translationFontSize * 0.24) {
                    Text(line.text)
                        .font(.system(
                            size: metrics.lyricFontSize,
                            weight: fontWeight,
                            design: fontDesign
                        ))
                        .foregroundStyle(reveal > 0 ? primaryStyle : pendingStyle)
                        .multilineTextAlignment(textAlignment)
                        .fixedSize(horizontal: false, vertical: true)

                    if !metrics.hidesTranslation,
                       let translation = line.translation,
                       !translation.isEmpty {
                        Text(translation)
                            .font(.system(
                                size: metrics.translationFontSize,
                                weight: .medium,
                                design: fontDesign
                            ))
                            .foregroundStyle(translationStyle)
                            .multilineTextAlignment(textAlignment)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: metrics.textWidth, alignment: frameAlignment)
                // 逐行浮入: 没到的行压暗下沉, 唱到时升起。静态海报 reveal 恒为
                // 1, 这三个修饰符全部取到中性值。
                .opacity(0.18 + 0.82 * revealEase(reveal))
                .offset(y: pendingOffset(reveal, context: context))
                .blur(radius: pendingBlur(reveal, context: context))
                .shadow(
                    color: shadow ?? .clear,
                    radius: context.scaled(18),
                    x: 0,
                    y: context.scaled(6)
                )
            }
        }
        .frame(width: metrics.textWidth, alignment: frameAlignment)
    }

    private var frameAlignment: Alignment {
        switch alignment {
        case .center: return .center
        case .trailing: return .trailing
        default: return .leading
        }
    }

    /// 缓出曲线。线性揭示会让每行"匀速爬"上来, 读起来像加载动画。
    private func revealEase(_ value: Double) -> Double {
        let clamped = min(max(value, 0), 1)
        return 1 - pow(1 - clamped, 2.2)
    }

    // 每个中间量都写死类型: Double(时间/进度) 和 CGFloat(尺寸) 混在一条长
    // 表达式里会把 Apple 端的类型检查顶到超时, 而 Linux 上的 parse 看不出来。
    private func pendingOffset(_ reveal: Double, context: LyricPosterRenderContext) -> CGFloat {
        let remaining = CGFloat(1 - revealEase(reveal))
        return context.scaled(26) * remaining
    }

    private func pendingBlur(_ reveal: Double, context: LyricPosterRenderContext) -> CGFloat {
        let remaining = CGFloat(1 - revealEase(reveal))
        return context.scaled(9) * remaining
    }
}

/// 海报署名: 封面缩略图 + 歌名歌手 + 应用名。
struct LyricPosterCreditView: View {
    let context: LyricPosterRenderContext
    let metrics: LyricPosterTypeMetrics
    var titleColor: Color
    var detailColor: Color
    var showsArtwork: Bool = true
    var artworkCorner: Double = 14

    var body: some View {
        HStack(spacing: context.scaled(20)) {
            if showsArtwork, let artwork = context.artworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: context.scaled(96), height: context.scaled(96))
                    .clipShape(RoundedRectangle(cornerRadius: context.scaled(artworkCorner), style: .continuous))
            }

            VStack(alignment: .leading, spacing: context.scaled(6)) {
                Text(context.content.songTitle)
                    .font(.system(size: metrics.titleFontSize, weight: .semibold, design: .rounded))
                    .foregroundStyle(titleColor)
                    .lineLimit(2)

                if let subtitle = subtitleText {
                    Text(subtitle)
                        .font(.system(size: metrics.captionFontSize, weight: .medium, design: .rounded))
                        .foregroundStyle(detailColor)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if context.showsCredit {
                VStack(alignment: .trailing, spacing: context.scaled(4)) {
                    Image(systemName: "music.note")
                        .font(.system(size: metrics.captionFontSize * 1.1, weight: .semibold))
                    Text(context.appName)
                        .font(.system(size: metrics.captionFontSize * 0.92, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(detailColor)
            }
        }
    }

    private var subtitleText: String? {
        let parts = [context.content.artistName, context.content.albumTitle].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// 封面模糊铺底。多个风格共用, 顺带把动态海报的缓慢推近也放在这里。
struct LyricPosterArtworkBackdrop: View {
    let context: LyricPosterRenderContext
    var blurRadius: Double = 90
    var overlayOpacity: Double = 0.45

    var body: some View {
        ZStack {
            context.palette.deep
            if let artwork = context.blurredArtworkImage {
                artwork
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    // 略微放大再缓推: 预模糊的图边缘已经发散, 不放大会露出画布底色。
                    .scaleEffect(CGFloat(1.12 + 0.08 * context.entrance))
                    .blur(radius: context.scaled(blurRadius * 0.25), opaque: true)
                    .overlay(context.palette.deep.opacity(overlayOpacity))
            } else {
                context.palette.backdropGradient
            }
        }
        // ImageRenderer 不会自动裁剪溢出内容, 放大后的封面必须显式切回画布。
        .frame(width: context.size.width, height: context.size.height)
        .clipped()
    }
}

/// 颗粒质感。纯色渐变在大画布上会有明显色带, 叠一层极淡噪点就消失了。
struct LyricPosterGrainOverlay: View {
    let context: LyricPosterRenderContext
    var opacity: Double = 0.05

    var body: some View {
        Canvas { canvasContext, size in
            var generator = SeededRandomGenerator(seed: 0x5EED)
            let dotSize = context.scaled(3)
            let width = Double(size.width)
            let height = Double(size.height)
            let count = Int(width * height / 2600)
            for _ in 0..<count {
                let x = Double.random(in: 0...width, using: &generator)
                let y = Double.random(in: 0...height, using: &generator)
                let alpha = Double.random(in: 0.25...1, using: &generator)
                let dot = CGRect(x: CGFloat(x), y: CGFloat(y), width: dotSize, height: dotSize)
                canvasContext.fill(Path(ellipseIn: dot), with: .color(.white.opacity(alpha)))
            }
        }
        .opacity(opacity)
        .blendMode(.overlay)
        .allowsHitTesting(false)
    }
}

/// 固定种子的随机源 —— 噪点必须每帧一致, 否则动态海报会"沙沙"闪。
struct SeededRandomGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
