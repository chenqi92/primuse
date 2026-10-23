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
    /// iPhone Duo 竖栏在尾侧时（外屏竖握、内屏横握）页面的滚动容器：封面铺到竖栏底下，文字行和按钮停在竖栏左侧。
    ///
    /// 容器本身照系统安全区排，行（歌名、下载键、⋯、开关、拖动把手）、分区标题与筛选控件都在竖栏左边，
    /// 不会压在竖排状态栏和系统的玻璃胶囊底下。横滑的卡片本来就顺着滚动方向伸进安全区，在屏幕边上露出下一张，
    /// 最后一张也能完整滚出来；整幅的封面网格挂 `pmCoversExtendUnderVerticalBar()` 铺到屏幕物理边缘
    /// （和 QQ 音乐一样第三列伸进竖栏）。竖排状态栏那一块垫一层渐隐的毛玻璃（和普通 iPhone 顶部状态栏下的
    /// 滚动边缘一样），滚上去的封面不和时间、信号叠字。
    ///
    /// 竖栏在前沿（外屏横握）时只照安全区排、网格不铺：那一侧是每一行的起点（封面、歌名）。
    /// 没有竖栏（普通 iPhone、iPad、Mac、Xcode 27.0 构建）时原样返回。
    func pmExtendsUnderVerticalBar() -> some View {
        modifier(PMVerticalBarContentFill())
    }
}

extension View {
    /// 自己已经连左右安全区一起出血、再按侧把内容垫回来的滚动页（详情页）用的那一半：
    /// 竖栏那一侧的滚动边缘加柔化，并把竖栏宽度交给里面要铺过去的封面网格。头图就在竖排状态栏底下，
    /// 不垫毛玻璃。垫回来的那一段由页面自己按 `pmVerticalBarEdge` 决定。
    func pmVerticalBarScrollEdge() -> some View {
        modifier(PMVerticalBarContentFill(coversStatusColumn: false))
    }

    /// 整幅的封面网格（专辑、歌单、艺人、流派……）在竖栏在尾侧时铺到屏幕的物理边缘，最右一列伸进竖栏，
    /// 系统的玻璃胶囊浮在封面上；离屏幕边缘的距离和普通 iPhone 一样。只给每一格就是一个整块按钮的网格用：
    /// 格子里带小按钮（播放、⋯、下载）的网格照旧停在竖栏左侧，不然最右一列的按钮一直被胶囊压着。
    /// 挂在网格外面那层（网格自己的左右留白之外也可以），网格要占满所在滚动容器的整幅宽度。
    /// `isEnabled` 为 false 时不铺（同一个网格换成带按钮的版式时用它，视图身份不随条件变）。
    /// 不在 `pmExtendsUnderVerticalBar()` / `pmVerticalBarScrollEdge()` 的容器里、或没有竖栏时原样返回。
    func pmCoversExtendUnderVerticalBar(_ isEnabled: Bool = true) -> some View {
        modifier(PMCoversExtendUnderVerticalBar(isEnabled: isEnabled))
    }

    /// 固定在页面上、不随内容滚动的横滑一排（电台的文件夹 / 标签筛选、极简的资料库分类行、目录路径条），
    /// 以及静止时就在竖排状态栏旁边的那一排（首页顶部的筛选胶囊）遇到系统竖栏时停在竖栏前。
    /// 横向 ScrollView 会顺着滚动方向伸进安全区，随内容滚动的卡片这样铺过去是有意的；这几排一直待在
    /// 竖排状态栏、摄像头或竖栏按钮旁边，滑过去的胶囊会和时间、按钮叠在一起。这时只画在这一排自己的
    /// 位置里（左右两侧都按竖栏停，外屏横握竖栏在前沿时同理）；上下不裁。
    /// 没有竖栏（普通 iPhone、iPad、Mac、Xcode 27.0 构建）时原样返回。
    func pmPinnedRowStopsAtVerticalBar() -> some View {
        modifier(PMPinnedRowClip())
    }

    /// 自己只裁左右、上下放开的横滑一排（首页封面轮播：卡片阴影要伸出上下沿）在竖栏在尾侧时，
    /// 尾侧多放开竖栏那么宽，卡片像别的横滑一样滑进竖栏底下，不在竖栏边上被齐刷刷切掉；
    /// 这一排自己的宽度和居中位置不变。不在 `pmExtendsUnderVerticalBar()` 的容器里、或没有竖栏时
    /// 和 `clipShape(PMHorizontalClipShape())` 一样。
    func pmHorizontalClipExtendingUnderVerticalBar() -> some View {
        modifier(PMHorizontalClipUnderVerticalBar())
    }
}

private struct PMVerticalBarOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// 竖栏在尾侧时，所在滚动容器的尾侧被竖栏占去多宽（`pmCoversExtendUnderVerticalBar()` 按它铺过去）；
    /// 没有竖栏、竖栏在前沿、或不在这类容器里时为 0。
    var pmVerticalBarOverlap: CGFloat {
        get { self[PMVerticalBarOverlapKey.self] }
        set { self[PMVerticalBarOverlapKey.self] = newValue }
    }
}

private struct PMCoversExtendUnderVerticalBar: ViewModifier {
    var isEnabled = true
    @Environment(\.pmVerticalBarOverlap) private var overlap

    func body(content: Content) -> some View {
        // 负的尾侧留白：网格按铺过去之后的宽度排列数，尾边落在屏幕边缘往里同样的距离。
        // 竖栏出现、消失时只改数值，视图身份不变（开合、转屏时网格不重建）。
        content.padding(.trailing, isEnabled ? -overlap : 0)
    }
}

private struct PMPinnedRowClip: ViewModifier {
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge

    func body(content: Content) -> some View {
        if verticalBarEdge != nil {
            // 裁的是外面这层框：横向 ScrollView 伸进安全区时伸的是它自己的框，外面这层仍是这一排
            // 在页面里的位置（不含竖栏那一条）。
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipShape(PMHorizontalClipShape())
        } else {
            content
        }
    }
}

/// 只在左右两侧裁、上下放开的裁切形状：胶囊按下时的放大、选中的光晕、卡片的阴影不被这一排的上下沿切掉。
/// `leftOverflow` / `rightOverflow` 是左右两边（屏幕上的方向，不随从右往左的语言翻转）各多放开多宽。
struct PMHorizontalClipShape: Shape {
    var leftOverflow: CGFloat = 0
    var rightOverflow: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        Path(CGRect(
            x: rect.minX - leftOverflow,
            y: rect.minY - 10_000,
            width: rect.width + leftOverflow + rightOverflow,
            height: rect.height + 20_000
        ))
    }
}

private struct PMHorizontalClipUnderVerticalBar: ViewModifier {
    @Environment(\.pmVerticalBarOverlap) private var overlap
    @Environment(\.layoutDirection) private var layoutDirection

    func body(content: Content) -> some View {
        // 形状按屏幕方向画：从右往左的语言里尾侧在左边。
        let isRightToLeft = layoutDirection == .rightToLeft
        content.clipShape(PMHorizontalClipShape(
            leftOverflow: isRightToLeft ? overlap : 0,
            rightOverflow: isRightToLeft ? 0 : overlap
        ))
    }
}

private struct PMVerticalBarContentFill: ViewModifier {
    var coversStatusColumn = true
    @Environment(\.pmVerticalBarEdge) private var verticalBarEdge
    /// 竖栏在容器尾侧占去的宽度（交给里面要铺过去的封面网格）。
    @State private var overlap: CGFloat = 0

    func body(content: Content) -> some View {
        #if os(iOS)
        if let verticalBarEdge {
            let trailing = verticalBarEdge == .trailing
            let filled = content
                .environment(\.pmVerticalBarOverlap, trailing ? overlap : 0)
                // 量的是伸到屏幕边缘的那层框上竖栏占去多宽；容器自己仍照安全区排。
                .background {
                    Color.clear
                        .ignoresSafeArea(.container, edges: .trailing)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.safeAreaInsets.trailing
                        } action: { overlap = $0 }
                }
                .overlay {
                    if trailing && coversStatusColumn {
                        GeometryReader { proxy in
                            if let column = PMStatusColumn.frame(in: proxy) {
                                // 遮挡区贴着竖栏底部时(外屏横握摄像头在右下角),毛玻璃从下往上淡出。
                                let fromBottom = column.midY > proxy.size.height / 2
                                PMStatusColumnEdge(fromBottom: fromBottom)
                                    .frame(width: column.width, height: column.height + 28)
                                    .offset(x: column.minX, y: fromBottom ? column.minY - 28 : column.minY)
                            }
                        }
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    }
                }
            if #available(iOS 26.0, *) {
                filled.scrollEdgeEffectStyle(.soft, for: trailing ? .trailing : .leading)
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
/// 往屏幕中间、往里两个方向都淡出，静止时看不出一块边。遮挡区在竖栏顶上时往下淡，在底下时往上淡。
private struct PMStatusColumnEdge: View {
    var fromBottom = false

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
                    startPoint: fromBottom ? .bottom : .top,
                    endPoint: fromBottom ? .top : .bottom
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
