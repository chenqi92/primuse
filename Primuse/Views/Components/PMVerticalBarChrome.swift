import SwiftUI

extension View {
    /// iPhone Duo 竖栏时，根页面的大标题留在顶部一条很薄的标题带里（顶部安全区是 0），
    /// 滚上去的内容隔着一层很淡的柔边就和标题叠在一起。这时顶部滚动边缘改成实底，
    /// 标题下面垫一层不透明的底。没有竖栏的设备（以及 iOS 26 以前）原样返回。
    func pmVerticalBarTitleEdge() -> some View {
        modifier(PMVerticalBarTitleEdge())
    }
}

private struct PMVerticalBarTitleEdge: ViewModifier {
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    func body(content: Content) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *), verticalBarEdge != nil {
            content.scrollEdgeEffectStyle(.hard, for: .top)
        } else {
            content
        }
        #else
        content
        #endif
    }
}
