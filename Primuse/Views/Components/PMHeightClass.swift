import SwiftUI

/// 手机横屏时纵向只剩三百多点，而各页的封面、头图、留白都是按竖屏标定的常量。
/// 这里给一个统一的判定和取值入口，调用处写「竖屏值 / 横屏值」一对数，
/// 不必各自去读尺寸等级、再写一串三元表达式。
///
/// 判定只看纵向尺寸等级：所有 iPhone 横屏都是紧凑高度（含横向为常规宽度的大屏机型），
/// iPad 与折叠屏内屏始终是常规高度，不会误入这条分支。
struct PMHeightClass: Equatable, Sendable {
    let isCompact: Bool

    /// 尺寸类取值。
    func value(_ regular: CGFloat, compact: CGFloat) -> CGFloat {
        isCompact ? compact : regular
    }

    /// 行数、字体、对齐这类非尺寸取值。
    func pick<T>(_ regular: T, compact: T) -> T {
        isCompact ? compact : regular
    }
}

extension EnvironmentValues {
    var pmHeightClass: PMHeightClass {
        #if os(iOS)
        PMHeightClass(isCompact: verticalSizeClass == .compact)
        #else
        // Mac 的窗口没有紧凑高度这一档，也不必依赖那边有没有纵向尺寸等级。
        PMHeightClass(isCompact: false)
        #endif
    }
}
