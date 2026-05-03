import SwiftUI
import PrimuseKit

/// 渲染单行 **激活态** 字级歌词。用 `AttributedString` 按 syllable 范围分别着色，
/// 多行 wrap 也能正确显示（mask 方案在多行下会跨行覆盖，已弃用）。
///
/// 由 `TimelineView(.animation)` 30Hz 驱动，配合外部 `timeAt(date)` 拿插值后的
/// 播放时间。代价：失去字内连续扫光渐变，改为字粒度突变——多行场景的正确性
/// 优先。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeColor: Color
    let inactiveColor: Color
    /// 把 `TimelineView` 的 `context.date` 翻译为外推后的播放秒数。
    let timeAt: (Date) -> TimeInterval

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: false)) { ctx in
            Text(attributed(at: timeAt(ctx.date)))
                .font(.system(size: fontSize, weight: weight))
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func attributed(at now: TimeInterval) -> AttributedString {
        guard let syllables = line.syllables, !syllables.isEmpty else {
            var s = AttributedString(line.text)
            s.foregroundColor = inactiveColor
            return s
        }
        var result = AttributedString()
        for syl in syllables {
            var piece = AttributedString(syl.text)
            // 已经过完整字 end → 完全唱过；
            // 进入字 start 但未完成 → 当前正在唱（保持高亮，不做字内渐变）；
            // 未到 → 未唱
            piece.foregroundColor = (now >= syl.start) ? activeColor : inactiveColor
            result.append(piece)
        }
        return result
    }
}
