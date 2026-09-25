import SwiftUI
import PrimuseKit

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
