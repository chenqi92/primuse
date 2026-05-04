import SwiftUI
import PrimuseKit

/// 渲染单行 **激活态** 字级歌词。用 `AttributedString` 按 syllable 范围分别着色,
/// 多行 wrap 也能正确显示 (mask 方案在多行下会跨行覆盖, 已弃用)。
///
/// 由 `TimelineView(.animation)` 60Hz 驱动, 配合外部 `timeAt(date)` 拿插值后的
/// 播放时间。
///
/// **丝滑改动 (2026-05)**:
/// - 字粒度从 bool 升级为 progress (0..1), 颜色在 inactive 和 active 间**插值**,
///   不再瞬切。消除「一个字一个字蹦出来变亮」的视觉硬切感。
/// - lookahead 提前唤醒: start 前 `lookaheadSec` 就开始过渡, 让「光」在字唱
///   出来那一刻已经基本到位。
/// - easeOut 曲线: 过渡前快后慢, 跟人耳节奏感对齐 (硬切 / 线性都显得机械)。
/// - 60Hz 而不是 30Hz: 让插值动画肉眼无颗粒。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeColor: Color
    let inactiveColor: Color
    /// 把 `TimelineView` 的 `context.date` 翻译为外推后的播放秒数。
    let timeAt: (Date) -> TimeInterval

    /// 提前进入过渡的时间 — 让字真正唱出来的时刻已经亮了 80-90%, 而不是
    /// 那一刻才开始变亮 (后者从用户视角看就是「滞后」)。
    private static let lookaheadSec: TimeInterval = 0.10

    /// 字内过渡跨度的下限 — 短字 (e.g. "啊" 30ms) 用 syllable 自身的 (end-start)
    /// 时长做过渡会瞬切跟原来差不多。强行至少给 180ms 让眼睛能跟上。
    private static let minTransitionSec: TimeInterval = 0.18

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
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
            piece.foregroundColor = color(for: syl, at: now)
            result.append(piece)
        }
        return result
    }

    /// 算这个字此刻该显示什么颜色 — 关键的「丝滑」来源。
    ///
    /// progress 计算:
    /// - 起点: `syl.start - lookaheadSec` (提前唤醒)
    /// - 终点: `syl.start + max(syl.duration, minTransitionSec)`
    /// - 时间在 [起点, 终点) 内做线性 0..1, easeOut 后做颜色插值。
    private func color(for syl: LyricSyllable, at now: TimeInterval) -> Color {
        let transitionStart = syl.start - Self.lookaheadSec
        let dur = max(syl.end - syl.start, Self.minTransitionSec)
        let transitionEnd = syl.start + dur

        if now <= transitionStart { return inactiveColor }
        if now >= transitionEnd { return activeColor }

        let raw = (now - transitionStart) / (transitionEnd - transitionStart)
        let eased = easeOut(raw)
        return Self.lerp(inactiveColor, activeColor, t: eased)
    }

    /// easeOut 曲线: 1 - (1-t)² —— 前半段快后半段慢, 视觉上感觉「光」一冲
    /// 上来很快就把字点亮, 然后稳住, 跟唱字的能量曲线吻合。
    private func easeOut(_ t: Double) -> Double {
        let clamped = max(0, min(1, t))
        return 1 - (1 - clamped) * (1 - clamped)
    }

    /// 在两个 SwiftUI Color 之间做 RGBA 线性插值。SwiftUI 没有内置 lerp,
    /// 走 UIColor 拿 RGBA 然后线性插。Color(.dynamicProvider) 不能直接拿
    /// 颜色值, fallback 到端点。
    nonisolated static func lerp(_ from: Color, _ to: Color, t: Double) -> Color {
        let clamped = max(0, min(1, t))
        let fromRGBA = rgba(from) ?? (1, 1, 1, 1)
        let toRGBA = rgba(to) ?? (1, 1, 1, 1)
        return Color(
            red: fromRGBA.r + (toRGBA.r - fromRGBA.r) * clamped,
            green: fromRGBA.g + (toRGBA.g - fromRGBA.g) * clamped,
            blue: fromRGBA.b + (toRGBA.b - fromRGBA.b) * clamped,
            opacity: fromRGBA.a + (toRGBA.a - fromRGBA.a) * clamped
        )
    }

    nonisolated static func rgba(_ color: Color) -> (r: Double, g: Double, b: Double, a: Double)? {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        let ui = UIColor(color)
        guard ui.getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
        return (Double(r), Double(g), Double(b), Double(a))
    }
}
