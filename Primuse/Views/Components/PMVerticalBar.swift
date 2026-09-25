import SwiftUI
import PrimuseKit
#if os(iOS)
import UIKit
#endif

/// iOS 27.1 起,iPhone Duo 这类设备会把状态栏、导航栏按钮、标签栏竖排进屏幕一侧的一条竖栏
/// (系统叫 vertical bar):那一侧多出一条安全区,顶部安全区变成 0。自绘的栏(极简的 tab 条)
/// 和贴着那一侧边缘的控件(歌曲页的字母索引)要跟着让位,系统给的信息都从这里读。
///
/// 这两样接口只有 iOS 27.1 SDK(SwiftUI 8.0.85 起)才有。用 Xcode 27.0 构建时整段编不进来,
/// 取值恒为「没有竖栏」,行为与改之前完全一样;用 Xcode 27.1 构建才读系统的值。
extension EnvironmentValues {
    /// 系统竖栏在哪一侧。系统在这台设备、这个方向上从不竖排时为 nil
    /// (普通 iPhone、iPad、Mac,以及 Xcode 27.0 构建的 App)。
    var pmVerticalBarEdge: HorizontalEdge? {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return toolbarVerticalEdge
        }
        #endif
        return nil
    }
}

enum PMReservedRegions {
    /// 与这块区域相交、正在生效的遮挡区(竖排的状态栏、前置摄像头)的上下沿,用这块区域自己的坐标。
    /// 没有这类遮挡,或者是 Xcode 27.0 构建时为空。
    static func activeOcclusionSpans(in proxy: GeometryProxy) -> [(minY: Double, maxY: Double)] {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map { (minY: Double($0.frame.minY), maxY: Double($0.frame.maxY)) }
        }
        #endif
        return []
    }

    /// 正在生效的遮挡区(竖排的状态栏、前置摄像头;灵动岛展开实时活动时会变大),用 proxy 自己的坐标。
    /// 播放页这类整屏居中的界面只让开这一块,见 `OcclusionAvoidancePolicy`。Xcode 27.0 构建时为空。
    /// 调试构建可以用 `PRIMUSE_DEBUG_OCCLUSION=trailing,84,320` 叠一块假的(模拟实时活动、iPad 取证)。
    static func activeOcclusions(in proxy: GeometryProxy) -> [OcclusionAvoidancePolicy.Region] {
        var regions: [OcclusionAvoidancePolicy.Region] = []
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            regions = proxy.reservedRegions(kind: .occlusion)
                .filter { $0.isActive }
                .map {
                    OcclusionAvoidancePolicy.Region(
                        x: Double($0.frame.minX),
                        y: Double($0.frame.minY),
                        width: Double($0.frame.width),
                        height: Double($0.frame.height)
                    )
                }
        }
        #endif
        #if DEBUG
        regions += OcclusionAvoidancePolicy.debugRegions(
            from: debugOcclusionSpecification,
            width: Double(proxy.size.width)
        )
        #endif
        return regions
    }

    #if DEBUG
    private static let debugOcclusionSpecification = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_OCCLUSION"]
    #endif
}

extension View {
    /// 横滑的一排(首页各区块、详情页「更多来自」、搜索页流派……)在系统竖栏前停住。
    ///
    /// 横向 ScrollView 会顺着滚动方向伸进安全区:普通 iPhone 横屏卡片在刘海下面继续露出来是系统习惯,
    /// 可 iPhone Duo 的竖栏是一条放着按钮与状态栏的控件区,卡片钻到它底下会被切成半张。有系统竖栏时
    /// 把伸进竖栏那一侧的部分裁掉;滚动边距系统已经按安全区给了,最后一张照样能完整滚出来。
    /// 没有竖栏(普通 iPhone、iPad、Mac、Xcode 27.0 构建)时原样返回。
    func pmStopsAtVerticalBar() -> some View {
        modifier(PMVerticalBarCarouselClip())
    }
}

private struct PMVerticalBarCarouselClip: ViewModifier {
    @Environment(\.pmVerticalBarEdge) private var edge
    @Environment(\.layoutDirection) private var layoutDirection
    /// 这一排在屏幕上的位置(窗口坐标)。
    @State private var frameInWindow: CGRect = .zero
    /// 窗口的尺寸与安全区:竖栏那条就是窗口那一侧的安全区。
    @State private var window = PMWindowMetrics()

    func body(content: Content) -> some View {
        if edge != nil {
            // 按屏幕上的实际位置算伸进竖栏多少:横向 ScrollView 在两侧伸进安全区的方式不一样
            // (竖握时顺着滚动方向伸到竖栏底下,横握时自己的安全区读数也会把竖栏算进去),
            // 只信窗口坐标。左右两侧各按窗口安全区裁,另一侧没有竖栏时安全区是 0,不裁。
            let left = max(0, window.safeLeft - frameInWindow.minX)
            let right = max(0, frameInWindow.maxX - (window.width - window.safeRight))
            let isRTL = layoutDirection == .rightToLeft
            content
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frameInWindow = $0 }
                .background {
                    #if os(iOS)
                    PMWindowMetricsReader { window = $0 }
                        .frame(width: 0, height: 0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                    #endif
                }
                .mask {
                    Rectangle()
                        .padding(.leading, isRTL ? right : left)
                        .padding(.trailing, isRTL ? left : right)
                }
        } else {
            content
        }
    }
}

/// 窗口的宽度与左右安全区(竖排的系统栏就在其中一侧的安全区里)。
struct PMWindowMetrics: Equatable {
    var width: CGFloat = .greatestFiniteMagnitude
    var safeLeft: CGFloat = 0
    var safeRight: CGFloat = 0
}

#if os(iOS)
/// 读所在窗口的宽度与左右安全区,变化时回报。
struct PMWindowMetricsReader: UIViewRepresentable {
    let onChange: (PMWindowMetrics) -> Void

    func makeUIView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateUIView(_ uiView: ReaderView, context: Context) {
        uiView.onChange = onChange
        uiView.publishIfNeeded()
    }

    final class ReaderView: UIView {
        var onChange: ((PMWindowMetrics) -> Void)?
        private var last: PMWindowMetrics?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            publishIfNeeded()
        }

        override func safeAreaInsetsDidChange() {
            super.safeAreaInsetsDidChange()
            publishIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            publishIfNeeded()
        }

        func publishIfNeeded() {
            guard let window else { return }
            let metrics = PMWindowMetrics(
                width: window.bounds.width,
                safeLeft: window.safeAreaInsets.left,
                safeRight: window.safeAreaInsets.right
            )
            guard metrics != last else { return }
            last = metrics
            DispatchQueue.main.async { [weak self] in
                self?.onChange?(metrics)
            }
        }
    }
}
#endif

extension ToolbarContent {
    /// 系统竖栏(iPhone Duo)空间不够时,这一组最后才收进系统溢出菜单。iOS 27 以前原样返回。
    @MainActor @ToolbarContentBuilder
    func pmHighVisibilityPriority() -> some ToolbarContent {
        if #available(iOS 27.0, macOS 26.1, *) {
            visibilityPriority(.high)
        } else {
            self
        }
    }
}
