import PrimuseKit
import SwiftUI

/// 全屏效果当前句的逐字浪尖（时间曲线见 `ImmersiveSyllableCrestPolicy`）。
///
/// 整句仍是一个 `Text`：换行、行数上限、放不下时缩小字号、从右往左的文字都交给系统排版，
/// 和逐行扫光时的版面一模一样；只在绘制时按字（每个字带一个 `ImmersiveSyllableIndex`）
/// 加上浮起、放大、发光和字内亮起。`TextRenderer` 要 iOS 18 / macOS 15 / tvOS 18，前两个就是最低系统；
/// tvOS 17 由调用方退回整句扫光。
@available(tvOS 18.0, *)
struct ImmersiveSyllableCrestText: View {
    let syllables: [LyricSyllable]
    let time: TimeInterval
    let fontSize: CGFloat
    let lineLimit: Int
    let textAlignment: TextAlignment
    let isRightToLeft: Bool
    let glowColor: Color
    /// 关掉时只逐字亮起，不浮起、不放大、不发光（减弱动态效果、歌词动效关闭、省电档）。
    let showsCrest: Bool

    var body: some View {
        indexedText
            .font(.system(size: fontSize, weight: .bold))
            .foregroundStyle(ImmersiveStagePalette.ink)
            .multilineTextAlignment(textAlignment)
            .lineLimit(lineLimit)
            .minimumScaleFactor(0.72)
            .fixedSize(horizontal: false, vertical: true)
            .textRenderer(ImmersiveSyllableCrestRenderer(
                appearances: ImmersiveSyllableCrestPolicy.appearances(for: syllables, at: time),
                fontSize: fontSize,
                glowColor: glowColor,
                isRightToLeft: isRightToLeft,
                showsCrest: showsCrest
            ))
    }

    /// 逐字拼回整句（字里自带词间空格），每个字标上下标，绘制时按下标取它此刻的状态。
    private var indexedText: Text {
        syllables.indices.reduce(Text(verbatim: "")) { text, index in
            let syllable = Text(verbatim: syllables[index].text)
                .customAttribute(ImmersiveSyllableIndex(index: index))
            return Text("\(text)\(syllable)")
        }
    }
}

@available(tvOS 18.0, *)
private struct ImmersiveSyllableIndex: TextAttribute {
    let index: Int
}

@available(tvOS 18.0, *)
private struct ImmersiveSyllableCrestRenderer: TextRenderer {
    let appearances: [ImmersiveSyllableCrestPolicy.Appearance]
    let fontSize: CGFloat
    let glowColor: Color
    let isRightToLeft: Bool
    let showsCrest: Bool

    /// 浪尖和光会画出字框，按最大幅度留边，免得被裁掉。只随字号变，不随时间变。
    var displayPadding: EdgeInsets {
        let overhang = (fontSize * CGFloat(ImmersiveSyllableCrestPolicy.maximumOverhangRatio)).rounded(.up)
        return EdgeInsets(top: overhang, leading: overhang, bottom: overhang, trailing: overhang)
    }

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        for line in layout {
            for run in line {
                guard let index = run[ImmersiveSyllableIndex.self]?.index,
                      appearances.indices.contains(index) else {
                    context.draw(run)
                    continue
                }
                draw(run, appearance: appearances[index], in: context)
            }
        }
    }

    private func draw(
        _ run: Text.Layout.Run,
        appearance: ImmersiveSyllableCrestPolicy.Appearance,
        in base: GraphicsContext
    ) {
        let bounds = run.typographicBounds.rect
        var context = base
        if showsCrest, appearance.crest > 0 {
            // 绕这个字的基线中点放大，再整体托起。
            let anchor = CGPoint(x: bounds.midX, y: run.typographicBounds.origin.y)
            context.translateBy(x: anchor.x, y: anchor.y - CGFloat(appearance.lift) * fontSize)
            context.scaleBy(x: CGFloat(appearance.scale), y: CGFloat(appearance.scale))
            context.translateBy(x: -anchor.x, y: -anchor.y)
        }

        if showsCrest, appearance.glow > 0 {
            var glow = context
            glow.addFilter(.shadow(
                color: glowColor.opacity(0.85 * appearance.glow),
                radius: fontSize * CGFloat(ImmersiveSyllableCrestPolicy.glowRadiusRatio * appearance.glow),
                options: .shadowOnly
            ))
            glow.draw(run)
        }

        if appearance.fill < 1 {
            var resting = context
            resting.opacity = showsCrest
                ? appearance.restingOpacity
                : ImmersiveSyllableCrestPolicy.restingOpacity
            resting.draw(run)
        }

        guard appearance.fill > 0 else { return }
        var lit = context
        if appearance.fill < 1 {
            // 亮起的边缘带一段渐隐，不是一刀切；边缘先从字外进来，亮满时整段已经越过字尾。
            let feather = min(fontSize * 0.3, max(bounds.width * 0.5, 1))
            let edge = CGFloat(appearance.fill) * (bounds.width + feather)
            let opaque: CGFloat
            let clear: CGFloat
            if isRightToLeft {
                clear = bounds.maxX - edge
                opaque = clear + feather
            } else {
                clear = bounds.minX + edge
                opaque = clear - feather
            }
            let area = bounds.insetBy(dx: -feather, dy: -fontSize)
            lit.clipToLayer { mask in
                mask.fill(
                    Path(area),
                    with: .linearGradient(
                        Gradient(colors: [.white, .clear]),
                        startPoint: CGPoint(x: opaque, y: bounds.midY),
                        endPoint: CGPoint(x: clear, y: bounds.midY)
                    )
                )
            }
        }
        lit.draw(run)
    }
}
