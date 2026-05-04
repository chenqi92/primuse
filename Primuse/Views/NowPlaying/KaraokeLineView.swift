import SwiftUI
import PrimuseKit

/// 渲染单行 **激活态** 字级歌词。每个 syllable 是独立的 Text, 走自定义
/// flow layout 自动换行。每帧由 60Hz `TimelineView(.animation)` 驱动。
///
/// 视觉细节 (向主流音乐 app 的字级歌词手感对齐):
/// - **字内 mask 扫光**: 每个 syllable 由两层 Text 叠加 — 底层 inactive 色,
///   顶层 active 色 + LinearGradient mask, mask 的「可见区」随 progress 从
///   左扫到右。单字内部能看到「左半亮右半暗」的过渡边一路扫过, 不再是
///   整字一起亮。
/// - **字级 bounce**: 当前唱的字 scale 1.0 → 1.04 → 1.0 走 sin 曲线, 像被
///   节奏「点」起来一下。anchor=.bottom 让字向上抬, 不影响行高。
/// - **lookahead 提前唤醒 100ms**: 字真正唱出来那一刻, 扫光已基本到位 +
///   bounce 在最高点, 跟人耳节奏感对齐。
/// - **easeOut 曲线**: 前快后慢, 跟唱字的能量曲线吻合。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeColor: Color
    let inactiveColor: Color
    /// 把 `TimelineView` 的 `context.date` 翻译为外推后的播放秒数。
    let timeAt: (Date) -> TimeInterval

    /// 提前进入过渡的时间 — 让字真正唱出来的时刻已经亮了 80-90%。
    private static let lookaheadSec: TimeInterval = 0.10

    /// 字内过渡跨度的下限 — 短字 (e.g. "啊" 30ms) 会瞬切, 强行至少 180ms。
    private static let minTransitionSec: TimeInterval = 0.18

    /// scale bounce 的峰值幅度 (1.0 → 1 + bumpAmount → 1.0)。
    private static let bumpAmount: Double = 0.05

    /// mask 扫光的边缘宽度 (0..1 progress 单位)。值越大边缘越柔, 越小越锐。
    /// 0.12 在汉字宽度上看着像一道柔光从左扫到右。
    private static let maskEdgeWidth: Double = 0.12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
            renderLine(at: timeAt(ctx.date))
        }
    }

    @ViewBuilder
    private func renderLine(at now: TimeInterval) -> some View {
        if let syllables = line.syllables, !syllables.isEmpty {
            LyricsFlowLayout {
                ForEach(syllables.indices, id: \.self) { i in
                    syllableView(syllables[i], at: now)
                }
            }
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
        let progress = computeProgress(syl: syl, now: now)
        let scale = 1.0 + Self.bumpAmount * bellCurve(progress)
        ZStack {
            // 底层: inactive 色, 总是显示
            Text(syl.text)
                .foregroundStyle(inactiveColor)
            // 顶层: active 色, 用 mask 露出 progress 部分
            Text(syl.text)
                .foregroundStyle(activeColor)
                .mask(sweepMask(progress: progress))
        }
        .font(.system(size: fontSize, weight: weight))
        .scaleEffect(scale, anchor: .bottom)
        // 防止 fixedSize 把多字节字符拆开
        .fixedSize()
    }

    /// 「扫光」mask: LinearGradient 从左到右, 在 progress 位置左侧实色 (露出
    /// active 色), 右侧透明 (露出底层 inactive 色)。中间 maskEdgeWidth
    /// 渐变成柔边, 像光头在字内左到右扫过。
    private func sweepMask(progress: Double) -> some View {
        let half = Self.maskEdgeWidth / 2
        let leftEnd = max(0, progress - half)
        let rightStart = min(1, progress + half)
        return LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: leftEnd),
                .init(color: .clear, location: rightStart),
                .init(color: .clear, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    /// 字级 progress 0..1: 时间 / 过渡跨度, easeOut。
    private func computeProgress(syl: LyricSyllable, now: TimeInterval) -> Double {
        let transitionStart = syl.start - Self.lookaheadSec
        let dur = max(syl.end - syl.start, Self.minTransitionSec)
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

    /// 0..1..0 钟形曲线, 让 scale bump 在 progress=0.5 处到峰值, 两端为 1.0。
    /// 用 sin(progress * π) 实现; 0 / 1 时为 0 (无 bump), 0.5 时为 1。
    private func bellCurve(_ progress: Double) -> Double {
        let c = max(0, min(1, progress))
        return sin(c * .pi)
    }
}

// MARK: - Custom flow layout

/// 字级歌词专用的 flow layout: 子 view 按顺序左到右排, 一行排不下就换行。
/// SwiftUI 没有内置的 wrapping HStack, 自己用 Layout protocol 实现。
///
/// 注意: 子 view 的 scaleEffect 不影响占位 (scaleEffect 只是渲染层缩放),
/// 所以放大不会让布局抖动。
struct LyricsFlowLayout: Layout {
    var spacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .greatestFiniteMagnitude
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxLineEnd: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
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

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                y += lineHeight
                lineHeight = 0
                x = 0
            }
            view.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
