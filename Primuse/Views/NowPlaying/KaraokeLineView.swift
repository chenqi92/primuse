import SwiftUI
import UIKit
import PrimuseKit

/// 渲染单行 **激活态** 字级歌词：底层暗色 Text + 上层亮色 Text 用遮罩裁切扫光。
/// 由 `TimelineView(.animation)` 驱动，60Hz 平滑刷新。
///
/// 进度计算按 **实际字符宽度**——CJK / 拉丁混排都贴合，避免英文歌词扫光跟字宽脱节。
/// 字宽用 UIFont + NSAttributedString.size 同步测量，按 `(line.id, fontSize)` 缓存。
struct KaraokeLineView: View {
    let line: LyricLine
    let fontSize: CGFloat
    let weight: Font.Weight
    let activeColor: Color
    let inactiveColor: Color
    let timeAt: (Date) -> TimeInterval

    @State private var cumulativeWidths: [CGFloat] = []   // [0, w0, w0+w1, ..., total]
    @State private var measuredFontSize: CGFloat = 0

    private var uiFont: UIFont {
        UIFont.systemFont(ofSize: fontSize, weight: weight.uiKitWeight)
    }
    private var font: Font { Font(uiFont) }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(line.text)
                .font(font)
                .foregroundStyle(inactiveColor)

            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { ctx in
                let progress = computeProgress(at: timeAt(ctx.date))
                Text(line.text)
                    .font(font)
                    .foregroundStyle(activeColor)
                    .mask(alignment: .leading) {
                        GeometryReader { geo in
                            Rectangle()
                                .frame(width: geo.size.width * progress)
                        }
                    }
            }
        }
        .multilineTextAlignment(.leading)
        .onAppear { ensureMeasured() }
        .onChange(of: fontSize) { _, _ in ensureMeasured() }
        .onChange(of: line.id) { _, _ in ensureMeasured() }
    }

    private func ensureMeasured() {
        guard let syllables = line.syllables, !syllables.isEmpty else {
            cumulativeWidths = []
            return
        }
        if measuredFontSize == fontSize, cumulativeWidths.count == syllables.count + 1 {
            return
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: uiFont]
        var acc: CGFloat = 0
        var widths: [CGFloat] = [0]
        widths.reserveCapacity(syllables.count + 1)
        for syl in syllables {
            let w = (syl.text as NSString).size(withAttributes: attrs).width
            acc += w
            widths.append(acc)
        }
        cumulativeWidths = widths
        measuredFontSize = fontSize
    }

    /// 当前进度 0...1。按累加宽度数组定位 syllable，字内按时间线性内插。
    /// 测量未完成（cumulativeWidths 为空）时退化为按字符数比例，避免首帧 0 闪烁。
    private func computeProgress(at now: TimeInterval) -> CGFloat {
        guard let syllables = line.syllables, !syllables.isEmpty else { return 0 }
        if now <= syllables.first!.start { return 0 }

        let useWidths = cumulativeWidths.count == syllables.count + 1 && cumulativeWidths.last! > 0
        let total: CGFloat = useWidths
            ? cumulativeWidths.last!
            : CGFloat(syllables.reduce(0) { $0 + $1.text.count })
        guard total > 0 else { return 0 }

        for (i, syl) in syllables.enumerated() {
            if now < syl.start {
                let prefix: CGFloat = useWidths
                    ? cumulativeWidths[i]
                    : CGFloat(syllables.prefix(i).reduce(0) { $0 + $1.text.count })
                return prefix / total
            }
            if now < syl.end {
                let dur = max(0.01, syl.end - syl.start)
                let intra = CGFloat((now - syl.start) / dur)
                let prefix: CGFloat = useWidths
                    ? cumulativeWidths[i]
                    : CGFloat(syllables.prefix(i).reduce(0) { $0 + $1.text.count })
                let sylWidth: CGFloat = useWidths
                    ? cumulativeWidths[i + 1] - cumulativeWidths[i]
                    : CGFloat(syl.text.count)
                return min(1.0, (prefix + sylWidth * intra) / total)
            }
        }
        return 1.0
    }
}

private extension Font.Weight {
    var uiKitWeight: UIFont.Weight {
        switch self {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
