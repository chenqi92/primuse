import SwiftUI

/// 随机播放、循环这类开关按钮的「已开启」底衬。
///
/// 这些按钮过去只靠图标换色区分开关，而播放界面的强调色会跟着封面取色走 ——
/// 遇上和正文色接近的封面，开与关几乎看不出差别，得盯着辨认。加一层圆形底色
/// 之后差异就从「色相不同」变成「有没有一块色块」，扫一眼就能确认。
///
/// 底圆尺寸由调用方给定而不是撑满按钮命中区：命中区通常比图标大不少，
/// 撑满会得到一个过分抢眼的大圆。开关两态都占同一个圆，切换时不会有布局跳动。
struct PlaybackToggleHighlight: ViewModifier {
    let isActive: Bool
    let tint: Color
    let diameter: CGFloat
    /// 关闭态的底色。默认完全透明；迷你播放器那种本来就有中性淡底的设计
    /// 可以传入原来的底色，保持它的观感。
    var inactiveFill: Color = .clear

    func body(content: Content) -> some View {
        content
            .background {
                Circle()
                    .fill(isActive ? tint.opacity(Self.activeFillOpacity) : inactiveFill)
                    .frame(width: diameter, height: diameter)
            }
            .animation(.easeOut(duration: 0.15), value: isActive)
    }

    /// 够亮到一眼可见，又不至于盖过图标本身。
    private static let activeFillOpacity: Double = 0.16
}

extension View {
    func playbackToggleHighlight(
        isActive: Bool,
        tint: Color,
        diameter: CGFloat,
        inactiveFill: Color = .clear
    ) -> some View {
        modifier(PlaybackToggleHighlight(
            isActive: isActive,
            tint: tint,
            diameter: diameter,
            inactiveFill: inactiveFill
        ))
    }
}
