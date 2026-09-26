import SwiftUI
import PrimuseKit

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

extension View {
    /// iPhone Duo 竖栏在尾侧时（外屏竖握、内屏横握），可滚动的内容横向铺到屏幕的物理边缘，系统竖栏的
    /// 玻璃胶囊（返回、工具栏、标签栏、搜索）浮在内容上 —— 和 iOS 26 起底部标签栏浮在列表上是同一个思路，
    /// 屏幕那一条不再空着。
    ///
    /// 挂在页面的滚动容器本身上：只有滚动的内容伸过去，行与卡片离屏幕边缘的距离和普通 iPhone 一样；
    /// 容器外面的固定元素（大标题、搜索框、字母索引、筛选条、浮动按钮、迷你条）仍按安全区留在竖栏另一侧。
    /// 随内容滚动的行尾按钮某些位置会被胶囊压住，和底部标签栏压住最后几行一样。竖排状态栏那一块垫一层
    /// 渐隐的毛玻璃（和普通 iPhone 顶部状态栏下的滚动边缘一样），滚到下面的内容不和时间、信号叠字。
    ///
    /// 竖栏在前沿（外屏横握）时不铺：那一侧是每一行的起点（封面、歌名），胶囊会把一整列行首盖住，
    /// 内容也会和按安全区排的标题错开；这时和普通 iPhone 横屏让开刘海一样按安全区排。
    /// 没有竖栏（普通 iPhone、iPad、Mac、Xcode 27.0 构建）时原样返回。
    func pmExtendsUnderVerticalBar() -> some View {
        modifier(PMVerticalBarContentFill())
    }
}

extension View {
    /// 自己已经连左右安全区一起出血、再按侧把内容垫回来的滚动页（详情页）用的那一半：
    /// 竖栏那一侧的滚动边缘加柔化。垫不垫竖栏那一侧由页面自己按 `pmVerticalBarEdge` 决定。
    func pmVerticalBarScrollEdge() -> some View {
        modifier(PMVerticalBarContentFill(extendsContent: false))
    }

    /// 铺到竖栏底下的滚动内容里，静止时就在最上面、带着可点按钮的那一块（歌单页头部的封面、标题与
    /// 播放 / 随机）照旧让开竖栏：那一段竖栏里是返回键和工具栏，不该叠在一起。
    /// 所在的滚动容器没有铺过去（普通 iPhone 等）时原样返回。
    func pmClearOfVerticalBar() -> some View {
        modifier(PMClearOfVerticalBar())
    }
}

private struct PMVerticalBarOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// `pmExtendsUnderVerticalBar()` 铺过去的滚动内容里，竖栏在尾侧盖住多宽；
    /// 没有竖栏、竖栏在前沿、或不在铺过去的容器里时为 0。
    var pmVerticalBarOverlap: CGFloat {
        get { self[PMVerticalBarOverlapKey.self] }
        set { self[PMVerticalBarOverlapKey.self] = newValue }
    }
}

private struct PMClearOfVerticalBar: ViewModifier {
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    @Environment(\.pmVerticalBarOverlap) private var overlap

    func body(content: Content) -> some View {
        if verticalBarEdge != nil {
            content.padding(.trailing, overlap)
        } else {
            content
        }
    }
}

private struct PMVerticalBarContentFill: ViewModifier {
    var extendsContent = true
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    /// 铺过去之后，竖栏盖住了容器尾侧多宽（交给里面要让开竖栏的头部）。
    @State private var overlap: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        if let verticalBarEdge {
            let fills = extendsContent && verticalBarEdge == .trailing
            let filled = content
                .environment(\.pmVerticalBarOverlap, fills ? overlap : 0)
                .ignoresSafeArea(.container, edges: fills ? .trailing : [])
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.safeAreaInsets.trailing
                } action: { overlap = $0 }
                .overlay {
                    if fills {
                        GeometryReader { proxy in
                            if let column = PMStatusColumn.frame(in: proxy) {
                                PMStatusColumnEdge()
                                    .frame(width: column.width, height: column.height + 28)
                                    .offset(x: column.minX, y: column.minY)
                            }
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            if #available(iOS 26.0, *) {
                filled.scrollEdgeEffectStyle(.soft, for: verticalBarEdge == .trailing ? .trailing : .leading)
            } else {
                filled
            }
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// 竖排状态栏（含前置摄像头）在一块区域里的位置：贴着尾侧的遮挡区并成一块，用这块区域自己的坐标。
private enum PMStatusColumn {
    static func frame(in proxy: GeometryProxy) -> CGRect? {
        let width = Double(proxy.size.width)
        let regions = PMReservedRegions.activeOcclusions(in: proxy)
            .filter { $0.maxX > width - 100 && $0.minX < width + 1 }
        guard let minX = regions.map({ $0.minX }).min(),
              let minY = regions.map({ $0.minY }).min(),
              let maxY = regions.map({ $0.maxY }).max()
        else { return nil }
        return CGRect(x: minX, y: minY, width: max(0, width - minX), height: maxY - minY)
    }
}

/// 竖排状态栏下面那层渐隐的毛玻璃：和普通 iPhone 顶部状态栏下的滚动边缘一个意思，
/// 往下、往里两个方向都淡出，静止时看不出一块边。
private struct PMStatusColumnEdge: View {
    var body: some View {
        Rectangle()
            .fill(.bar)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.72),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.3),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
    }
}
#endif
