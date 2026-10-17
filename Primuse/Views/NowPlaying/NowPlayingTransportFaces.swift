import SwiftUI

/// 播放页的播放 / 暂停键面,按「播放页样式与按钮」里选的样式画。播放页和设置里那张预览共用。
///
/// `diameter` 是这颗键的边长(竖屏 56、iPad 横屏 60)。实心圆与细圆圈直接用系统符号,和一直以来
/// 同一个大小;不带框的三角按边长的七成画;圆角方块里的三角挖空,露出底下的背景,和实心圆一样。
struct NowPlayingPlayPauseFace: View {
    let style: NowPlayingPlayButtonStyle
    let showsPause: Bool
    let diameter: CGFloat
    let tint: Color

    var body: some View {
        switch style {
        case .filledCircle:
            glyph(showsPause ? "pause.circle.fill" : "play.circle.fill", size: diameter)
        case .outlinedCircle:
            glyph(showsPause ? "pause.circle" : "play.circle", size: diameter, weight: .light)
        case .plain:
            glyph(showsPause ? "pause.fill" : "play.fill", size: diameter * 0.68)
        case .filledSquare:
            let side = diameter * 0.9
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(tint)
                    .frame(width: side, height: side)
                Image(systemName: showsPause ? "pause.fill" : "play.fill")
                    .font(.system(size: diameter * 0.38, weight: .semibold))
                    // 三角的视觉重心偏左,往右挪一点才像居中。
                    .offset(x: showsPause ? 0 : diameter * 0.025)
                    .contentTransition(.symbolEffect(.replace))
                    .blendMode(.destinationOut)
            }
            .compositingGroup()
            .frame(width: diameter, height: diameter)
        }
    }

    private func glyph(_ symbol: String, size: CGFloat, weight: Font.Weight = .regular) -> some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
    }
}

extension NowPlayingSkipButtonStyle {
    /// 播放页上一首 / 下一首的字号。默认那一档就是一直以来的 `.title`。
    var font: Font {
        switch self {
        case .standard, .track: .title
        case .bold, .filledCircle, .outlinedCircle: font(scale: 1)
        }
    }

    /// 同一种字号按比例缩小(设置里的小样)。`.title` 按 28 点算。
    func font(scale: CGFloat) -> Font {
        switch self {
        case .standard, .track: .system(size: 28 * scale)
        case .bold: .system(size: 36 * scale, weight: .heavy)
        case .filledCircle: .system(size: 40 * scale)
        case .outlinedCircle: .system(size: 40 * scale, weight: .light)
        }
    }
}
