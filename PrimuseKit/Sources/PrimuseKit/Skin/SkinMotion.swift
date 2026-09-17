import Foundation

/// 动效位。和颜色一样,视图只写名字 —— 曲线与时长由当前样式给出。
///
/// 进这张表的是「多处共用的动效词汇」。某个组件自己的装饰性动画(比如封面墙每隔
/// 几秒换一次构图的节拍)留在那个组件里,不进表。
public enum SkinMotionToken: String, CaseIterable, Sendable, Codable {
    /// 选中指示在同级项之间移动(分类 chip、分段、磁贴)。
    case selection
    /// 顶栏分类行的收起与展开。
    case chromeCollapse
    /// 进出详情页时顶栏的淡出与复位。
    case chromeReveal
    /// 顶栏切换页面时的内容替换。
    case pageSwitch
    /// 按压反馈。
    case press
    /// 面板与浮层的出入。
    case sheet
    /// 列表、卡片首次出现。
    case contentAppear
    /// 头图换构图(封面墙重排)。
    case heroReflow
    /// 头图聚焦到某一张封面。
    case heroFocus
}

/// 一条动效的取值。只描述曲线,不依赖 SwiftUI,所以能在本机断言。
public enum SkinMotionSpec: Sendable, Equatable, Codable {
    case spring(response: Double, dampingFraction: Double)
    /// SwiftUI 的 `.smooth`。
    case smooth(duration: Double, extraBounce: Double)
    case easeInOut(duration: Double)
    case easeOut(duration: Double)
    case linear(duration: Double)
    /// 不做动画。
    case none

    public var isWellFormed: Bool {
        switch self {
        case .spring(let response, let dampingFraction):
            return response > 0 && response <= 5 && dampingFraction > 0 && dampingFraction <= 2
        case .smooth(let duration, let extraBounce):
            return duration > 0 && duration <= 10 && (-1...1).contains(extraBounce)
        case .easeInOut(let duration), .easeOut(let duration), .linear(let duration):
            return duration > 0 && duration <= 10
        case .none:
            return true
        }
    }

    /// 大致的收敛时间(秒)。用来安排「动画结束后再做某事」,不是精确值。
    public var settleDuration: Double {
        switch self {
        case .spring(let response, _): return response * 1.6
        case .smooth(let duration, _): return duration
        case .easeInOut(let duration), .easeOut(let duration), .linear(let duration): return duration
        case .none: return 0
        }
    }
}
