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
        #if DEBUG
        if pmDebugSuppressesVerticalBar {
            // 取证框模拟的视口:只在能有竖栏的构建(27.1 SDK)里按它自己的那一条排。
            #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
            return pmDebugSimulatedVerticalBarEdge
            #else
            return nil
            #endif
        }
        #endif
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

    /// 正在生效的折叠区(iPhone Duo 内屏半折时屏幕中间弯过去的那一条),用 proxy 自己的坐标。
    /// 摊平或合上时没有;Xcode 27.0 构建时为空。
    static func activeDivisions(in proxy: GeometryProxy) -> [OcclusionAvoidancePolicy.Region] {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return proxy.reservedRegions(kind: .division)
                .filter { $0.isActive && $0.frame.width > 0 && $0.frame.height > 0 }
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
        return []
    }

    #if DEBUG
    private static let debugOcclusionSpecification = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_OCCLUSION"]
    #endif
}

private struct PMIsPhoneIdiomKey: EnvironmentKey {
    static let defaultValue = false
}

#if DEBUG
private struct PMDebugFoldAxisKey: EnvironmentKey {
    static let defaultValue: Axis? = nil
}

private struct PMDebugSuppressesVerticalBarKey: EnvironmentKey {
    static let defaultValue = false
}

private struct PMDebugSimulatedVerticalBarEdgeKey: EnvironmentKey {
    static let defaultValue: HorizontalEdge? = nil
}
#endif

extension EnvironmentValues {
    /// 这台设备是 iPhone(含 iPhone Duo 的内外屏)。宽画布上重排成两栏(详情页、首页、播放页分栏)
    /// 只在 iPhone 的常规宽度上做 —— iPad 有自己的侧边栏版式,不跟着变。根视图按设备写入;
    /// 调试取证页在 iPad 模拟器里模拟 Duo 内屏时把它设为 true。
    var pmIsPhoneIdiom: Bool {
        get { self[PMIsPhoneIdiomKey.self] }
        set { self[PMIsPhoneIdiomKey.self] = newValue }
    }

    #if DEBUG
    /// 调试取证页模拟的折叠方向:`.horizontal` 是桌面半折(折痕横在屏幕中间),`.vertical` 是书本半折。
    var pmDebugFoldAxis: Axis? {
        get { self[PMDebugFoldAxisKey.self] }
        set { self[PMDebugFoldAxisKey.self] = newValue }
    }

    /// 调试取证页在 Duo 外屏上模拟内屏时,框里当作没有系统竖栏。
    var pmDebugSuppressesVerticalBar: Bool {
        get { self[PMDebugSuppressesVerticalBarKey.self] }
        set { self[PMDebugSuppressesVerticalBarKey.self] = newValue }
    }

    /// 取证框模拟的视口本身有系统竖栏(内屏横握、外屏竖握)时,框里按这一侧有竖栏排
    /// (外屏自己的竖栏照旧不算)。
    var pmDebugSimulatedVerticalBarEdge: HorizontalEdge? {
        get { self[PMDebugSimulatedVerticalBarEdgeKey.self] }
        set { self[PMDebugSimulatedVerticalBarEdgeKey.self] = newValue }
    }
    #endif
}

/// iOS 27.1 的 `ArrangementView`(主视图 + 次视图,按尺寸、方向与折叠区自己决定并排还是只显示主视图)。
enum PMArrangement {
    /// 这次构建与这台设备上有没有 `ArrangementView`。Xcode 27.0 构建与 iOS 27.1 以前恒为 false,
    /// 调用方据此整条不走分栏,行为与改之前完全一样。
    static var isAvailable: Bool {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            return true
        }
        #endif
        return false
    }
}

/// 左右分栏的 `ArrangementView`:只允许水平分(比宽高的时候只显示主视图),次视图为空时整幅给主视图。
/// 半折成书本时分界自动对齐折痕。没有 `ArrangementView` 的构建里退回普通的左右并排
/// (调用方先看 `PMArrangement.isAvailable`,正常不会走到)。
struct PMHorizontalArrangement<Primary: View, Secondary: View>: View {
    private let primary: Primary
    private let secondary: Secondary

    init(@ViewBuilder primary: () -> Primary, @ViewBuilder secondary: () -> Secondary) {
        self.primary = primary()
        self.secondary = secondary()
    }

    var body: some View {
        #if os(iOS) && canImport(SwiftUI, _version: 8.0.85)
        if #available(iOS 27.1, *) {
            ArrangementView {
                primary
            } secondary: {
                secondary
            }
            .arrangementViewStyle(.split.axes(.horizontal))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        HStack(spacing: 0) {
            primary
            secondary
        }
    }
}

extension View {
    /// 横滑的一排(首页各区块、详情页「更多来自」、搜索页流派……)遇到系统竖栏时怎么排。
    ///
    /// iPhone Duo 的竖栏是一列浮在内容上的玻璃胶囊:竖栏在尾侧时页面的滚动内容铺到屏幕物理边缘
    /// (`pmExtendsUnderVerticalBar()`),横滑的卡片也和其它内容一样铺到屏幕边缘、像普通 iPhone 那样
    /// 在屏幕边上露出下一张,胶囊浮在上面,不在竖栏前截断。竖栏在前沿(外屏横握)、或所在页面没有铺过去时,
    /// 横向 ScrollView 本来就顺着滚动方向伸进安全区、滚动边距也按安全区给了,静止时第一张照旧在竖栏外,
    /// 最后一张照样能完整滚出来。所以这里不再裁切;留着这个入口是为了规则再变时只改一处。
    func pmStopsAtVerticalBar() -> some View {
        self
    }
}

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

/// 工具栏按钮的标签。系统竖栏(iPhone Duo)时给出标题 + 图标:竖栏里按图标排,收进系统溢出菜单时用标题;
/// 其它时候仍是原来的纯图标 —— 普通 iPhone 的导航栏把 Label 的图标排得和单独一张 Image 差一个像素,
/// 这样那边逐像素不变。
struct PMToolbarItemLabel: View {
    private let title: Text
    private let systemImage: String
    private let titled: Bool

    init(_ titleKey: LocalizedStringKey, systemImage: String, titled: Bool) {
        title = Text(titleKey)
        self.systemImage = systemImage
        self.titled = titled
    }

    init(verbatim title: String, systemImage: String, titled: Bool) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.titled = titled
    }

    var body: some View {
        if titled {
            Label {
                title
            } icon: {
                Image(systemName: systemImage)
            }
        } else {
            Image(systemName: systemImage)
        }
    }
}
