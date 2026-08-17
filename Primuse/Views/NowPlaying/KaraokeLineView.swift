import SwiftUI
import PrimuseKit

/// 渲染单行 **激活态** 字级歌词。每个 syllable 是独立的 Text, 走自定义
/// flow layout 自动换行。每帧由 60Hz `TimelineView(.animation)` 驱动。
///
/// 字级动效细节:
/// - **字内 mask 扫光**: 每个 syllable 由两层 Text 叠加 — 底层 inactive 色,
///   顶层 active 色 + LinearGradient mask, mask 的「可见区」随 progress 沿
///   书写方向扫过。单字内部能看到柔和的明暗过渡, 不再是
///   整字一起亮。
/// - **字级 bounce**: 当前唱的字 scale 1.0 → 1.04 → 1.0 走 sin 曲线, 像被
///   节奏「点」起来一下。anchor=.bottom 让字向上抬, 不影响行高。
/// - **lookahead 提前唤醒 100ms**: 字真正唱出来那一刻, 扫光已基本到位。
///   bounce 不提前, 避免切行前先弹一下旧句子。
/// - **easeOut 曲线**: 前快后慢, 跟唱字的能量曲线吻合。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeColor: Color
    let inactiveColor: Color
    /// Presentation direction resolved from the document's `[la:...]` header.
    /// This only mirrors the lyric subtree; syllable storage and timestamps
    /// remain in their original order.
    let writingDirection: LyricWritingDirection
    /// 把 `TimelineView` 的 `context.date` 翻译为外推后的播放秒数。
    let timeAt: (Date) -> TimeInterval
    /// 外层已经有 TimelineView 时传入固定时间，避免嵌套 60Hz 刷新。
    let fixedTime: TimeInterval?
    /// Inactive word-level rows keep the same flow layout without running a
    /// Timeline. This prevents active-row takeover from changing wrapping or
    /// measured height while still avoiding unnecessary 60 Hz updates.
    let isAnimationEnabled: Bool
    /// 超过该时间后，这一行已经让位给下一行；即使外层 active index 还没刷新，
    /// 也不要继续在旧行上扫光或弹动。
    let deactivationTime: TimeInterval?

    init(
        line: LyricLine,
        fontSize: CGFloat,
        weight: Font.Weight,
        activeColor: Color,
        inactiveColor: Color,
        writingDirection: LyricWritingDirection = .natural,
        timeAt: @escaping (Date) -> TimeInterval,
        fixedTime: TimeInterval? = nil,
        isAnimationEnabled: Bool = true,
        deactivationTime: TimeInterval? = nil
    ) {
        self.line = line
        self.fontSize = fontSize
        self.weight = weight
        self.activeColor = activeColor
        self.inactiveColor = inactiveColor
        self.writingDirection = writingDirection
        self.timeAt = timeAt
        self.fixedTime = fixedTime
        self.isAnimationEnabled = isAnimationEnabled
        self.deactivationTime = deactivationTime
    }

    /// 扫光提前进入过渡的时间 — 让字真正唱出来的时刻已经亮了 80-90%。
    private static let lookaheadSec: TimeInterval = 0.10

    /// 字内过渡跨度的下限 — 短字 (e.g. "啊" 30ms) 会瞬切, 强行至少 180ms。
    private static let minTransitionSec: TimeInterval = 0.18

    /// scale bounce 的峰值幅度 (1.0 → 1 + bumpAmount → 1.0)。
    private static let bumpAmount: Double = 0.05

    /// mask 扫光的边缘宽度 (0..1 progress 单位)。值越大边缘越柔, 越小越锐。
    /// 0.12 在汉字宽度上看着像一道柔光从左扫到右。
    private static let maskEdgeWidth: Double = 0.12

    @Environment(\.layoutDirection) private var inheritedLayoutDirection

    private var lyricLayoutDirection: LayoutDirection {
        switch writingDirection {
        case .natural:
            inheritedLayoutDirection
        case .leftToRight:
            .leftToRight
        case .rightToLeft:
            .rightToLeft
        }
    }

    var body: some View {
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
        .environment(\.layoutDirection, lyricLayoutDirection)
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
            LyricsFlowLayout(
                measurementKey: fontSize,
                layoutDirection: lyricLayoutDirection
            ) {
                ForEach(syllables.indices, id: \.self) { i in
                    syllableView(syllables[i], at: now)
                        .environment(\.layoutDirection, lyricLayoutDirection)
                }
            }
            // Keep the custom layout's coordinate space physical. Individual
            // lyric views still receive the document direction for shaping.
            .environment(\.layoutDirection, .leftToRight)
        } else {
            Text(line.text)
                .font(.system(size: fontSize, weight: weight))
                .foregroundStyle(inactiveColor)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func renderInactiveLine() -> some View {
        if let syllables = line.syllables, !syllables.isEmpty {
            LyricsFlowLayout(
                measurementKey: fontSize,
                layoutDirection: lyricLayoutDirection
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
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 单个 syllable: 双层 Text + 扫光 mask + scale bounce。
    @ViewBuilder
    private func syllableView(_ syl: LyricSyllable, at now: TimeInterval) -> some View {
        let sweepProgress = computeSweepProgress(syl: syl, now: now)
        let bumpProgress = computeBumpProgress(syl: syl, now: now)
        let scale = 1.0 + Self.bumpAmount * bellCurve(bumpProgress)
        ZStack {
            // 底层: inactive 色, 总是显示
            Text(syl.text)
                .foregroundStyle(inactiveColor)
            // 顶层: active 色, 用 mask 露出 progress 部分
            Text(syl.text)
                .foregroundStyle(activeColor)
                .mask(sweepMask(progress: sweepProgress))
        }
        .font(.system(size: fontSize, weight: weight))
        .scaleEffect(scale, anchor: .bottom)
        // 防止 fixedSize 把多字节字符拆开
        .fixedSize()
    }

    /// 「扫光」mask: 沿文档书写方向推进；只改变字内的视觉填充方向，
    /// syllable 的存储顺序与时间轴保持不变。
    private func sweepMask(progress: Double) -> some View {
        let half = Self.maskEdgeWidth / 2
        let leftEnd = max(0, progress - half)
        let rightStart = min(1, progress + half)
        let startPoint = lyricLayoutDirection == .rightToLeft
            ? UnitPoint.trailing
            : UnitPoint.leading
        let endPoint = lyricLayoutDirection == .rightToLeft
            ? UnitPoint.leading
            : UnitPoint.trailing
        return LinearGradient(
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

    /// 扫光 progress 0..1: 可以提前预热, 让唱到该字时亮度已经跟上。
    private func computeSweepProgress(syl: LyricSyllable, now: TimeInterval) -> Double {
        let transitionStart = syl.start - Self.lookaheadSec
        let dur = max(syl.end - syl.start, Self.minTransitionSec)
        let transitionEnd = syl.start + dur
        if now <= transitionStart { return 0 }
        if now >= transitionEnd { return 1 }
        let raw = (now - transitionStart) / (transitionEnd - transitionStart)
        return easeOut(raw)
    }

    /// bounce progress 不提前。切行时先切到新句, 再在新句的第一个字上弹动。
    private func computeBumpProgress(syl: LyricSyllable, now: TimeInterval) -> Double {
        let transitionStart = syl.start
        let dur = max(syl.end - syl.start, Self.minTransitionSec)
        let transitionEnd = syl.start + dur
        if now <= transitionStart { return 0 }
        if now >= transitionEnd { return 1 }
        return (now - transitionStart) / (transitionEnd - transitionStart)
    }

    private func easeOut(_ t: Double) -> Double {
        let c = max(0, min(1, t))
        return 1 - (1 - c) * (1 - c)
    }

    /// 0..1..0 钟形曲线, 让 scale bump 在 progress=0.5 处到峰值, 两端为 1.0。
    /// 用 sin(progress * π) 实现; 0 / 1 时为 0 (无 bump), 0.5 时为 1。
    private func bellCurve(_ progress: Double) -> Double {
        let c = max(0, min(1, progress))
        return sin(c * .pi)
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
    var measurementKey: CGFloat = 0
    var layoutDirection: LayoutDirection = .leftToRight

    struct Cache {
        var sizes: [CGSize] = []
        var measurementKey: CGFloat = 0
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: measure(subviews), measurementKey: measurementKey)
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache.sizes = measure(subviews)
        cache.measurementKey = measurementKey
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
        let placements = LyricFlowPlacementPolicy.placements(
            itemSizes: cache.sizes.map {
                LyricFlowItemSize(width: Double($0.width), height: Double($0.height))
            },
            containerWidth: Double(bounds.width),
            spacing: Double(spacing),
            isRightToLeft: layoutDirection == .rightToLeft
        )

        for placement in placements {
            let index = subviews.index(subviews.startIndex, offsetBy: placement.itemIndex)
            let view = subviews[index]
            let size = cache.sizes[placement.itemIndex]
            view.place(
                at: CGPoint(
                    x: bounds.minX + CGFloat(placement.x),
                    y: bounds.minY + CGFloat(placement.y)
                ),
                anchor: UnitPoint(x: 0, y: 0),
                proposal: ProposedViewSize(size)
            )
        }
    }

    private func ensureMeasurements(in cache: inout Cache, subviews: Subviews) {
        if cache.sizes.count != subviews.count || cache.measurementKey != measurementKey {
            cache.sizes = measure(subviews)
            cache.measurementKey = measurementKey
        }
    }

    private func measure(_ subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }
}
