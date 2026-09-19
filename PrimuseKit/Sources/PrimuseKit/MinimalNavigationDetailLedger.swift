import Foundation

/// 极简模式详情页向顶栏汇报的转场节点。
public enum MinimalNavigationDetailTransitionEvent: Sendable, Equatable {
    /// 详情页将要显示:新 push,或者被取消的返回。
    case appearing
    /// 系统认得出的返回转场开始了,顶栏跟着转场一起回来。
    case popping
    /// 详情页已经离开导航栈或被拆掉。不论系统有没有走过一次认得出的返回转场,
    /// 这一条都会到,登记因此不会比页面活得更久。
    case removed
}

/// 极简模式下「哪些页签正压着详情页」的登记簿,顶栏据此隐藏。
///
/// 三路信号各有早晚:`appearing` / `popping` 来自 UIKit 转场回调,比 SwiftUI 的
/// preference 早一拍,顶栏才能跟转场动画同步收放;`mounted` 是 preference 给出的
/// 「视图树里确实还挂着详情页」,晚,但不会错。
///
/// 转场回调不是成对到达的。卡片放大转场的拖拽返回可以中途换一只手势接管:先开始的
/// 那次以「已取消」收尾,真正带走页面的那次未必再走一遍认得出的返回。只靠
/// `popping` 销账时,这种页面的登记就永远留着,顶栏再也不出现,而极简模式的全部导航
/// 都在顶栏上。所以销账以 `removed` 为准,`popping` 只负责让顶栏早一点回来。
public struct MinimalNavigationDetailLedger<Scope: Hashable & Sendable>: Sendable, Equatable {
    /// 转场回调登记的、正在显示的详情页。
    public private(set) var presented: [UUID: Scope] = [:]
    /// 正在返回途中的页签:详情页还挂着,但顶栏应当已经回来。
    public private(set) var returning: Set<Scope> = []
    /// preference 汇报的、视图树里挂着详情页的页签。
    public private(set) var mounted: Set<Scope> = []

    public init() {}

    /// 参与「是否隐藏顶栏」判定的页签。
    public var detailScopes: Set<Scope> {
        mounted.union(presented.values)
    }

    public func hidesTopNavigation(for scope: Scope) -> Bool {
        detailScopes.contains(scope) && !returning.contains(scope)
    }

    public mutating func record(
        _ event: MinimalNavigationDetailTransitionEvent,
        id: UUID,
        scope: Scope
    ) {
        switch event {
        case .appearing:
            presented[id] = scope
            returning.remove(scope)
        case .popping:
            presented[id] = nil
            if !presented.values.contains(scope) {
                returning.insert(scope)
            }
        case .removed:
            presented[id] = nil
            // 没走过返回转场就消失的页面不需要「返回途中」这个状态;留着它会让同一
            // 页签下一张详情页在 preference 先到时短暂露出顶栏。
            if !detailScopes.contains(scope) {
                returning.remove(scope)
            }
        }
    }

    public mutating func updateMounted(_ scopes: Set<Scope>) {
        mounted = scopes
        returning.formIntersection(scopes)
    }
}
