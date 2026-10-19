import SwiftUI

/// 播放页的播放 / 暂停键面,按「播放页样式与按钮」里选的样式画。音乐、有声书、播客、电台的播放页
/// 和设置里那张预览共用(#329)。
///
/// `diameter` 是这颗键的边长(竖屏 56、iPad 横屏 60)。实心圆与细圆圈直接用系统符号,和一直以来
/// 同一个大小;不带框的三角按边长的八成多画,比标准的上一首 / 下一首稍大一些;圆角方块里的三角挖空,
/// 露出底下的背景,和实心圆一样。`stops` 为真(电台)时播着显示停止,不是暂停。
struct NowPlayingPlayPauseFace: View {
    let style: NowPlayingPlayButtonStyle
    let showsPause: Bool
    let diameter: CGFloat
    let tint: Color
    var stops = false

    /// 不带框时符号的字号占边长的比例。0.68 时暂停只有 22.5×32 点,比 28 号的上一首(38×22)还显小(#329)。
    static let plainGlyphScale: CGFloat = 0.82

    var body: some View {
        let pause = stops ? "stop" : "pause"
        switch style {
        case .filledCircle:
            glyph(showsPause ? "\(pause).circle.fill" : "play.circle.fill", size: diameter)
        case .outlinedCircle:
            glyph(showsPause ? "\(pause).circle" : "play.circle", size: diameter, weight: .light)
        case .plain:
            glyph(showsPause ? "\(pause).fill" : "play.fill", size: diameter * Self.plainGlyphScale)
        case .filledSquare:
            let side = diameter * 0.9
            ZStack {
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(tint)
                    .frame(width: side, height: side)
                Image(systemName: showsPause ? "\(pause).fill" : "play.fill")
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

    /// 电台上一台 / 下一台的字号:比上一首 / 下一首小一号,默认那一档就是一直以来的 `.title3`(#329)。
    var compactFont: Font {
        switch self {
        case .standard, .track: .title3
        case .bold, .filledCircle, .outlinedCircle: font(scale: 0.72)
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
