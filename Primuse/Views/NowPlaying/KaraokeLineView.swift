import SwiftUI
import PrimuseKit

struct LyricsFlowMeasurementKey: Equatable {
    var line: LyricLine?
    var fontSize: CGFloat
    var weight: Font.Weight
    var layoutDirection: LayoutDirection

    init(
        line: LyricLine? = nil,
        fontSize: CGFloat = 0,
        weight: Font.Weight = .regular,
        layoutDirection: LayoutDirection = .leftToRight
    ) {
        self.line = line
        self.fontSize = fontSize
        self.weight = weight
        self.layoutDirection = layoutDirection
    }
}

/// 渲染单行 **激活态** 字级歌词。每个 syllable 是独立的 Text, 走自定义
/// flow layout 自动换行。支持传统逐帧渲染，以及把播放时钟隔离到纯绘制
/// progress mask 的布局稳定模式。
///
/// 字级动效细节:
/// - **字内 mask 扫光**: 底层逐字绘制 inactive 色，整行 active 填充通过
///   每个 syllable 的进度 mask 露出。这样既保留字内过渡，也能让渐变色
///   在整行坐标系连续绘制。
/// - **字级上浮**: 唱到的字随演唱浮起、略微放大并停在那里, 整句唱完再一起落回
///   (参照 Apple Music, 见 `LyricSyllableEmphasisPolicy`)。都是渲染层变换,
///   不影响行高与换行。
/// - **柔光**: 深色歌词上正在唱的字带一圈同色柔光, 唱完后散去。
/// - **lookahead 提前唤醒 100ms**: 字真正唱出来那一刻, 扫光已基本到位。
///   放大不提前, 避免切行前先抬一下旧句子。
/// - **easeOut 曲线**: 前快后慢, 跟唱字的能量曲线吻合。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeStyle: AnyShapeStyle
    let inactiveColor: Color
    let textAlignment: TextAlignment
    /// Document-level fallback resolved from metadata or aggregate lyric text.
    /// Each row refines that fallback from its own text so an English row in
    /// a Persian document keeps its natural reading order.
    let writingDirection: LyricWritingDirection
    /// 把 `TimelineView` 的 `context.date` 翻译为外推后的播放秒数。
    let timeAt: (Date) -> TimeInterval
    /// 外层已经有 TimelineView 时传入固定时间，避免嵌套 60Hz 刷新。
    let fixedTime: TimeInterval?
    /// Paused or detached playback keeps the current highlight snapshot without
    /// retaining a display-rate clock.
    let isPlaybackActive: Bool
    /// Inactive word-level rows keep the same flow layout without running a
    /// Timeline. This prevents active-row takeover from changing wrapping or
    /// measured height while still avoiding unnecessary 60 Hz updates.
    let isAnimationEnabled: Bool
    /// Progress can be rendered at a fixed playback time while the motion-only
    /// glow is disabled for paused, inactive, or Reduce Motion states. The
    /// raised size of sung words is state, not motion, so it stays put when
    /// paused and only Reduce Motion turns it off.
    let animatesSyllableBounce: Bool
    /// 正在唱的字带柔光。只适合浅色字压在深色底上（深色字的「光」读起来像污渍），
    /// 由调用方按当时的配色决定。
    let glowsSungSyllables: Bool
    /// macOS lyrics keep both flow layouts outside TimelineView. Only a Canvas
    /// mask receives playback ticks, so glyph measurement and row placement do
    /// not become display-rate work.
    let isolatesAnimatedProgressFromLayout: Bool
    /// 超过该时间后，这一行已经让位给下一行；即使外层 active index 还没刷新，
    /// 也不要继续在旧行上扫光或弹动。
    let deactivationTime: TimeInterval?

    init(
        line: LyricLine,
        fontSize: CGFloat,
        weight: Font.Weight,
        activeStyle: AnyShapeStyle,
        inactiveColor: Color,
        textAlignment: TextAlignment = .leading,
        writingDirection: LyricWritingDirection = .natural,
        timeAt: @escaping (Date) -> TimeInterval,
        fixedTime: TimeInterval? = nil,
        isPlaybackActive: Bool = true,
        isAnimationEnabled: Bool = true,
        animatesSyllableBounce: Bool = true,
        isolatesAnimatedProgressFromLayout: Bool = false,
        deactivationTime: TimeInterval? = nil,
        glowsSungSyllables: Bool = false
    ) {
        self.line = line
        self.fontSize = fontSize
        self.weight = weight
        self.activeStyle = activeStyle
        self.inactiveColor = inactiveColor
        self.textAlignment = textAlignment
        self.writingDirection = writingDirection
        self.timeAt = timeAt
        self.fixedTime = fixedTime
        self.isPlaybackActive = isPlaybackActive
        self.isAnimationEnabled = isAnimationEnabled
        self.animatesSyllableBounce = animatesSyllableBounce
        self.isolatesAnimatedProgressFromLayout = isolatesAnimatedProgressFromLayout
        self.deactivationTime = deactivationTime
        self.glowsSungSyllables = glowsSungSyllables
    }

    init(
        line: LyricLine,
        fontSize: CGFloat,
        weight: Font.Weight,
        activeColor: Color,
        inactiveColor: Color,
        textAlignment: TextAlignment = .leading,
        writingDirection: LyricWritingDirection = .natural,
        timeAt: @escaping (Date) -> TimeInterval,
        fixedTime: TimeInterval? = nil,
        isPlaybackActive: Bool = true,
        isAnimationEnabled: Bool = true,
        animatesSyllableBounce: Bool = true,
        isolatesAnimatedProgressFromLayout: Bool = false,
        deactivationTime: TimeInterval? = nil,
        glowsSungSyllables: Bool = false
    ) {
        self.init(
            line: line,
            fontSize: fontSize,
            weight: weight,
            activeStyle: AnyShapeStyle(activeColor),
            inactiveColor: inactiveColor,
            textAlignment: textAlignment,
            writingDirection: writingDirection,
            timeAt: timeAt,
            fixedTime: fixedTime,
            isPlaybackActive: isPlaybackActive,
            isAnimationEnabled: isAnimationEnabled,
            animatesSyllableBounce: animatesSyllableBounce,
            isolatesAnimatedProgressFromLayout: isolatesAnimatedProgressFromLayout,
            deactivationTime: deactivationTime,
            glowsSungSyllables: glowsSungSyllables
        )
    }

    /// 扫光提前进入过渡的时间 — 让字真正唱出来的时刻已经亮了 80-90%。
    private static let lookaheadSec: TimeInterval = 0.10

    /// 柔光半径与字号之比、最亮时的不透明度。
    private static let glowRadiusRatio: CGFloat = 0.22
    private static let glowOpacity: Double = 0.85

    /// mask 扫光的边缘宽度 (0..1 progress 单位)。值越大边缘越柔, 越小越锐。
    /// 0.12 在汉字宽度上看着像一道柔光从左扫到右。
    private static let maskEdgeWidth: Double = 0.12

    @Environment(\.layoutDirection) private var inheritedLayoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsSyllableLift: Bool { !reduceMotion }

    private var showsSyllableGlow: Bool {
        glowsSungSyllables && animatesSyllableBounce && !reduceMotion
    }

    /// 柔光与上浮都会画到行框外面，扫光那层要比行框大一圈才不会被裁掉。只随参数变，
    /// 暂停/继续不改它，渐变色歌词的色带位置也就不会跟着跳。
    private var activeLayerOverhang: CGFloat {
        let lift = (fontSize * LyricSyllableEmphasisPolicy.raisedLiftRatio).rounded(.up) + 1
        return glowsSungSyllables ? max(lift, (fontSize * Self.glowRadiusRatio * 2).rounded(.up)) : lift
    }

    private var resolvedWritingDirection: LyricWritingDirection {
        LyricWritingDirectionPolicy.resolvePresentationDirection(
            for: line,
            documentFallback: writingDirection
        )
    }

    private var lyricLayoutDirection: LayoutDirection {
        switch resolvedWritingDirection {
        case .natural:
            inheritedLayoutDirection
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        }
    }

    private var flowMeasurementKey: LyricsFlowMeasurementKey {
        LyricsFlowMeasurementKey(
            line: line,
            fontSize: fontSize,
            weight: weight,
            layoutDirection: lyricLayoutDirection
        )
    }

    var body: some View {
        Group {
            if isolatesAnimatedProgressFromLayout {
                layoutIsolatedBody
            } else {
                layoutDrivenBody
            }
        }
        .environment(\.layoutDirection, lyricLayoutDirection)
    }

    @ViewBuilder
    private var layoutDrivenBody: some View {
        Group {
            if let fixedTime {
                if isAnimationEnabled {
                    renderLineRespectingDeactivation(at: fixedTime)
                } else {
                    renderInactiveLine()
                }
            } else {
                TimelineView(
                    .animation(minimumInterval: 1.0 / 60.0, paused: !isAnimationEnabled)
                ) { ctx in
                    if isAnimationEnabled {
                        renderLineRespectingDeactivation(at: timeAt(ctx.date))
                    } else {
                        renderInactiveLine()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var layoutIsolatedBody: some View {
        let plan = KaraokeTimelineUpdatePolicy.plan(
            isLineActive: isAnimationEnabled,
            isPlaybackActive: isPlaybackActive,
            hasFixedPlaybackTime: fixedTime != nil,
            reduceMotion: reduceMotion
        )

        if plan.rendersSyllableProgress,
           let syllables = line.syllables,
           !syllables.isEmpty {
            layoutIsolatedSyllableLine(syllables, plan: plan)
        } else {
            renderInactiveLine()
        }
    }

    @ViewBuilder
    private func renderLineRespectingDeactivation(at now: TimeInterval) -> some View {
        if let deactivationTime, now >= deactivationTime {
            renderInactiveLine()
        } else {
            renderLine(at: now)
        }
    }

    @ViewBuilder
    private func renderLine(at now: TimeInterval) -> some View {
        if let syllables = line.syllables, !syllables.isEmpty {
            let hold = showsSyllableLift
                ? LyricSyllableEmphasisPolicy.lineHold(
                    syllables: syllables,
                    deactivationTime: deactivationTime,
                    at: now
                )
                : 0
            inactiveSyllableLayer(syllables, lineHold: hold, at: now)
                .overlay {
                    Rectangle()
                        .fill(activeStyle)
                        .mask {
                            activeSyllableMask(syllables, lineHold: hold, at: now)
                                .padding(activeLayerOverhang)
                        }
                        .padding(-activeLayerOverhang)
                }
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(inactiveColor)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func renderInactiveLine() -> some View {
        if let syllables = line.syllables, !syllables.isEmpty {
            LyricsFlowLayout(
                measurementKey: flowMeasurementKey,
                layoutDirection: lyricLayoutDirection,
                textAlignment: textAlignment
            ) {
                ForEach(syllables.indices, id: \.self) { i in
                    Text(syllables[i].text)
                        .font(.system(size: fontSize, weight: weight))
                        .foregroundStyle(inactiveColor)
                        .fixedSize()
                        .environment(\.layoutDirection, lyricLayoutDirection)
                }
            }
            .environment(\.layoutDirection, .leftToRight)
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(inactiveColor)
                .multilineTextAlignment(textAlignment)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func layoutIsolatedSyllableLine(
        _ syllables: [LyricSyllable],
        plan: KaraokeTimelineUpdatePlan
    ) -> some View {
        isolatedInactiveSyllableLayer(syllables)
            .overlay {
                isolatedActiveSyllableLayer(syllables, plan: plan)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(line.text))
    }

    private func isolatedInactiveSyllableLayer(
        _ syllables: [LyricSyllable]
    ) -> some View {
        LyricsFlowLayout(
            measurementKey: flowMeasurementKey,
            layoutDirection: lyricLayoutDirection,
            textAlignment: textAlignment
        ) {
            ForEach(syllables.indices, id: \.self) { index in
                Text(syllables[index].text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(inactiveColor)
                    .fixedSize()
                    .environment(\.layoutDirection, lyricLayoutDirection)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func isolatedActiveSyllableLayer(
        _ syllables: [LyricSyllable],
        plan: KaraokeTimelineUpdatePlan
    ) -> some View {
        Rectangle()
            .fill(activeStyle)
            .mask {
                LyricsFlowLayout(
                    measurementKey: flowMeasurementKey,
                    layoutDirection: lyricLayoutDirection,
                    textAlignment: textAlignment
                ) {
                    ForEach(syllables.indices, id: \.self) { index in
                        Text(syllables[index].text)
                            .font(.system(size: fontSize, weight: weight))
                            .foregroundStyle(.white)
                            .fixedSize()
                            .environment(\.layoutDirection, lyricLayoutDirection)
                    }
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .mask {
                if plan.runsTimeline, let minimumInterval = plan.minimumInterval {
                    TimelineView(.animation(minimumInterval: minimumInterval)) { context in
                        isolatedProgressMask(
                            syllables,
                            at: timeAt(context.date)
                        )
                    }
                } else {
                    isolatedProgressMask(
                        syllables,
                        at: fixedTime ?? timeAt(Date())
                    )
                }
            }
            .accessibilityHidden(true)
            .allowsHitTesting(false)
    }

    private func isolatedProgressMask(
        _ syllables: [LyricSyllable],
        at now: TimeInterval
    ) -> some View {
        Canvas { context, size in
            guard deactivationTime.map({ now < $0 }) ?? true else { return }

            let resolvedSymbols = syllables.indices.map { index in
                context.resolveSymbol(id: index)
            }
            let placements = LyricFlowPlacementPolicy.placements(
                itemSizes: resolvedSymbols.map { symbol in
                    guard let symbol else { return LyricFlowItemSize(width: 0, height: 0) }
                    return LyricFlowItemSize(
                        width: Double(symbol.size.width),
                        height: Double(symbol.size.height)
                    )
                },
                containerWidth: Double(size.width),
                spacing: 0,
                isRightToLeft: lyricLayoutDirection == .rightToLeft,
                alignment: flowAlignment
            )

            for placement in placements {
                let index = placement.itemIndex
                guard let symbol = resolvedSymbols[index] else { continue }
                let frame = CGRect(
                    x: CGFloat(placement.x),
                    y: CGFloat(placement.y),
                    width: symbol.size.width,
                    height: symbol.size.height
                )
                let nextStart = syllables.indices.contains(index + 1)
                    ? syllables[index + 1].start
                    : nil
                let progress = computeSweepProgress(
                    syl: syllables[index],
                    nextSyllableStart: nextStart,
                    now: now
                )
                guard progress > 0 else { continue }

                let path = Path(frame)
                if progress >= 1 {
                    context.fill(path, with: .color(.white))
                    continue
                }

                let half = Self.maskEdgeWidth / 2
                let leadingEnd = max(0, progress - half)
                let trailingStart = min(1, progress + half)
                let gradient = Gradient(stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: leadingEnd),
                    .init(color: .clear, location: trailingStart),
                    .init(color: .clear, location: 1),
                ])
                let startPoint = lyricLayoutDirection == .rightToLeft
                    ? CGPoint(x: frame.maxX, y: frame.midY)
                    : CGPoint(x: frame.minX, y: frame.midY)
                let endPoint = lyricLayoutDirection == .rightToLeft
                    ? CGPoint(x: frame.minX, y: frame.midY)
                    : CGPoint(x: frame.maxX, y: frame.midY)
                context.fill(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: startPoint,
                        endPoint: endPoint
                    )
                )
            }
        } symbols: {
            ForEach(syllables.indices, id: \.self) { index in
                Text(syllables[index].text)
                    .font(.system(size: fontSize, weight: weight))
                    .foregroundStyle(.white)
                    .fixedSize()
                    .environment(\.layoutDirection, lyricLayoutDirection)
                    .tag(index)
            }
        }
    }

    private var flowAlignment: LyricFlowHorizontalAlignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }

    private func inactiveSyllableLayer(
        _ syllables: [LyricSyllable],
        lineHold: Double,
        at now: TimeInterval
    ) -> some View {
        LyricsFlowLayout(
            measurementKey: flowMeasurementKey,
            layoutDirection: lyricLayoutDirection,
            textAlignment: textAlignment
        ) {
            ForEach(syllables.indices, id: \.self) { index in
                inactiveSyllable(
                    syllables[index],
                    nextSyllableStart: syllables.indices.contains(index + 1)
                        ? syllables[index + 1].start
                        : nil,
                    lineHold: lineHold,
                    at: now
                )
                    .environment(\.layoutDirection, lyricLayoutDirection)
            }
        }
        // Keep the custom layout's coordinate space physical. Individual
        // lyric views still receive the document direction for shaping.
        .environment(\.layoutDirection, .leftToRight)
    }

    private func activeSyllableMask(
        _ syllables: [LyricSyllable],
        lineHold: Double,
        at now: TimeInterval
    ) -> some View {
        LyricsFlowLayout(
            measurementKey: flowMeasurementKey,
            layoutDirection: lyricLayoutDirection,
            textAlignment: textAlignment
        ) {
            ForEach(syllables.indices, id: \.self) { index in
                activeSyllableMask(
                    syllables[index],
                    nextSyllableStart: syllables.indices.contains(index + 1)
                        ? syllables[index + 1].start
                        : nil,
                    lineHold: lineHold,
                    at: now
                )
                    .environment(\.layoutDirection, lyricLayoutDirection)
            }
        }
        .environment(\.layoutDirection, .leftToRight)
    }

    private func inactiveSyllable(
        _ syllable: LyricSyllable,
        nextSyllableStart: TimeInterval?,
        lineHold: Double,
        at now: TimeInterval
    ) -> some View {
        let raise = syllableRaise(
            syllable,
            nextSyllableStart: nextSyllableStart,
            lineHold: lineHold,
            at: now
        )
        return Text(syllable.text)
            .foregroundStyle(inactiveColor)
            .font(.system(size: fontSize, weight: weight))
            .modifier(SyllableRaise(amount: raise, fontSize: fontSize))
            .fixedSize()
    }

    private func activeSyllableMask(
        _ syllable: LyricSyllable,
        nextSyllableStart: TimeInterval?,
        lineHold: Double,
        at now: TimeInterval
    ) -> some View {
        let sweepProgress = computeSweepProgress(
            syl: syllable,
            nextSyllableStart: nextSyllableStart,
            now: now
        )
        let raise = syllableRaise(
            syllable,
            nextSyllableStart: nextSyllableStart,
            lineHold: lineHold,
            at: now
        )
        let glow = showsSyllableGlow
            ? LyricSyllableEmphasisPolicy.glow(
                for: syllable,
                nextSyllableStart: nextSyllableStart,
                at: now
            )
            : 0
        // 柔光画在遮罩里：白色光晕的透明度透出上面那层歌词色，光就是歌词本身的颜色。
        return Text(syllable.text)
            .foregroundStyle(.white)
            .font(.system(size: fontSize, weight: weight))
            .mask(sweepMask(progress: sweepProgress))
            .modifier(SyllableGlow(intensity: glow * Self.glowOpacity, radius: fontSize * Self.glowRadiusRatio))
            .modifier(SyllableRaise(amount: raise, fontSize: fontSize))
            .fixedSize()
    }

    /// 0...1：这个字现在浮起了多少（整句落回时一起乘下去）。
    private func syllableRaise(
        _ syllable: LyricSyllable,
        nextSyllableStart: TimeInterval?,
        lineHold: Double,
        at now: TimeInterval
    ) -> Double {
        guard showsSyllableLift, lineHold > 0 else { return 0 }
        return LyricSyllableEmphasisPolicy.rise(
            for: syllable,
            nextSyllableStart: nextSyllableStart,
            at: now
        ) * lineHold
    }

    /// 「扫光」mask: 沿文档书写方向推进；只改变字内的视觉填充方向，
    /// syllable 的存储顺序与时间轴保持不变。
    @ViewBuilder
    private func sweepMask(progress: Double) -> some View {
        let clampedProgress = max(0, min(1, progress))
        if clampedProgress <= 0 {
            Color.clear
        } else if clampedProgress >= 1 {
            Color.black
        } else {
            let half = Self.maskEdgeWidth / 2
            let leftEnd = max(0, clampedProgress - half)
            let rightStart = min(1, clampedProgress + half)
            let startPoint = lyricLayoutDirection == .rightToLeft
                ? UnitPoint.trailing
                : UnitPoint.leading
            let endPoint = lyricLayoutDirection == .rightToLeft
                ? UnitPoint.leading
                : UnitPoint.trailing
            LinearGradient(
                stops: [
                    .init(color: .black, location: 0),
                    .init(color: .black, location: leftEnd),
                    .init(color: .clear, location: rightStart),
                    .init(color: .clear, location: 1),
                ],
                startPoint: startPoint,
                endPoint: endPoint
            )
        }
    }

    /// 扫光 progress 0..1: 可以提前预热, 让唱到该字时亮度已经跟上。
    private func computeSweepProgress(
        syl: LyricSyllable,
        nextSyllableStart: TimeInterval?,
        now: TimeInterval
    ) -> Double {
        let transitionStart = syl.start - Self.lookaheadSec
        let dur = LyricSyllablePlaybackTimingPolicy.effectiveDuration(
            for: syl,
            nextSyllableStart: nextSyllableStart
        )
        let transitionEnd = syl.start + dur
        if now <= transitionStart { return 0 }
        if now >= transitionEnd { return 1 }
        let raw = (now - transitionStart) / (transitionEnd - transitionStart)
        return easeOut(raw)
    }

    private func easeOut(_ t: Double) -> Double {
        let c = max(0, min(1, t))
        return 1 - (1 - c) * (1 - c)
    }
}

/// 唱过的字浮起并略微放大。底层暗字与上层亮字用同一个变换，两层始终对齐。
private struct SyllableRaise: ViewModifier {
    let amount: Double
    let fontSize: CGFloat

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + LyricSyllableEmphasisPolicy.raisedScale * amount, anchor: .bottom)
            .offset(y: -fontSize * LyricSyllableEmphasisPolicy.raisedLiftRatio * amount)
    }
}

/// 光晕只在有光的那几帧挂上，其余时候不多一层阴影渲染。
private struct SyllableGlow: ViewModifier {
    let intensity: Double
    let radius: CGFloat

    func body(content: Content) -> some View {
        if intensity > 0.01 {
            content.shadow(color: .white.opacity(min(1, intensity)), radius: radius)
        } else {
            content
        }
    }
}

// MARK: - Custom flow layout

/// 字级歌词专用的 flow layout: 子 view 按逻辑顺序沿书写方向排布，一行排不下就换行。
/// SwiftUI 没有内置的 wrapping HStack, 自己用 Layout protocol 实现。
///
/// 注意: 子 view 的 scaleEffect 不影响占位 (scaleEffect 只是渲染层缩放),
/// 所以放大不会让布局抖动。
struct LyricsFlowLayout: Layout {
    var spacing: CGFloat = 0
    var measurementKey = LyricsFlowMeasurementKey()
    var layoutDirection: LayoutDirection = .leftToRight
    var textAlignment: TextAlignment = .leading

    struct PlacementCacheKey: Equatable {
        let sizes: [CGSize]
        let containerWidth: CGFloat
        let spacing: CGFloat
        let layoutDirection: LayoutDirection
        let textAlignment: TextAlignment
    }

    struct Cache {
        var sizes: [CGSize] = []
        var measurementKey = LyricsFlowMeasurementKey()
        var placementKey: PlacementCacheKey?
        var placements: [LyricFlowItemPlacement] = []
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: measure(subviews), measurementKey: measurementKey)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        guard cache.sizes.count != subviews.count || cache.measurementKey != measurementKey else {
            return
        }
        cache.sizes = measure(subviews)
        cache.measurementKey = measurementKey
        cache.placementKey = nil
        cache.placements = []
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        ensureMeasurements(in: &cache, subviews: subviews)
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineEnd: CGFloat = 0

        for size in cache.sizes {
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight
                lineHeight = 0
                x = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            maxLineEnd = max(maxLineEnd, x - spacing)
        }
        y += lineHeight
        return CGSize(width: min(maxLineEnd, maxWidth), height: y)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        ensureMeasurements(in: &cache, subviews: subviews)
        let placementKey = PlacementCacheKey(
            sizes: cache.sizes,
            containerWidth: bounds.width,
            spacing: spacing,
            layoutDirection: layoutDirection,
            textAlignment: textAlignment
        )
        if cache.placementKey != placementKey {
            cache.placements = LyricFlowPlacementPolicy.placements(
                itemSizes: cache.sizes.map {
                    LyricFlowItemSize(width: Double($0.width), height: Double($0.height))
                },
                containerWidth: Double(bounds.width),
                spacing: Double(spacing),
                isRightToLeft: layoutDirection == .rightToLeft,
                alignment: flowAlignment
            )
            cache.placementKey = placementKey
        }

        for placement in cache.placements {
            let index = subviews.index(subviews.startIndex, offsetBy: placement.itemIndex)
            let view = subviews[index]
            view.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(placement.x),
                    y: bounds.minY + CGFloat(placement.y)
                ),
                anchor: UnitPoint(x: 0, y: 0),
                // 缓存的理想尺寸只负责换行与坐标。放置时再次给出精确宽度会让
                // RTL 连写字形重新塑形，并在像素取整后被 Text 截断为省略号。
                proposal: .unspecified
            )
        }
    }

    private func ensureMeasurements(in cache: inout Cache, subviews: Subviews) {
        if cache.sizes.count != subviews.count || cache.measurementKey != measurementKey {
            cache.sizes = measure(subviews)
            cache.measurementKey = measurementKey
            cache.placementKey = nil
            cache.placements = []
        }
    }

    private func measure(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    private var flowAlignment: LyricFlowHorizontalAlignment {
        switch textAlignment {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
