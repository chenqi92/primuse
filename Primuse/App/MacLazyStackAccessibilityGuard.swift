#if os(macOS)
import AppKit
import OSLog

private let lazyStackAccessibilityLog = Logger(subsystem: "com.welape.yuanyin", category: "Accessibility")

/// 接管 SwiftUI 惰性堆栈辅助功能节点的「滚到底」动作，免得辅助功能客户端一调就把 App 带崩。
///
/// macOS 27.0（26A428）上，`LazyVStack`/`LazyHStack` 在辅助功能树里是一个
/// `AccessibilityLazyLayoutNode`，只暴露 `AXScrollToTop` 与 `AXScrollToBottom` 两个动作。
/// 执行 `AXScrollToBottom` 时它要把全部行的标识列一遍（`LazyScrollable.applyCollectionViewIDs`），
/// 还没实例化过的行得现场求值 `ForEach` 的内容闭包；这个动作是从运行循环直接派发来的，
/// 不在任何视图图更新里，`AGAttribute.syncMainIfReferences` 发现没有当前更新批次就断言失败
/// （`EXC_BREAKPOINT`）。一个只有 `ScrollView { LazyVStack { ForEach { Text } } }` 的最小
/// 程序在两百行左右就能复现，和行里放什么、数据怎么标识都无关；换成 `List`（表格视图）不崩。
///
/// 这里不再调用系统实现，改用 AppKit 把所在的滚动视图滚到内容末尾，效果与用户拖到底相同。
/// `AXScrollToTop` 不经过那条路径，照旧交给系统。
enum MacLazyStackAccessibilityGuard {
    private static let installation: Void = installScrollToEndHook()

    /// 只装一次；越早越好，辅助功能客户端可能在第一个窗口出现时就连上来。
    static func install() {
        _ = installation
    }

    private static let nodeClassName = "SwiftUI.AccessibilityLazyLayoutNode"
    private static let scrollToEndAction = "AXScrollToBottom"
    /// 惰性行高是估算值：滚到末尾后新露出的行实际排版，文档尺寸还会变，
    /// 得在尺寸稳定后再贴一次边。
    private static let settlePasses = 4
    private static let settleDelay: TimeInterval = 0.12

    private typealias PerformActionIMP = @convention(c) (AnyObject, Selector, AnyObject) -> Bool

    private static func installScrollToEndHook() {
        guard let nodeClass = NSClassFromString(nodeClassName) else {
            lazyStackAccessibilityLog.info("Lazy stack accessibility guard not installed: \(nodeClassName, privacy: .public) not found")
            return
        }
        let selector = NSSelectorFromString("accessibilityPerformAction:")
        // 只改这个类自己的实现；方法要是继承来的，改了会波及所有辅助功能节点。
        guard let method = ownInstanceMethod(of: nodeClass, selector: selector) else {
            lazyStackAccessibilityLog.info("Lazy stack accessibility guard not installed: accessibilityPerformAction: not overridden")
            return
        }
        let original = unsafeBitCast(method_getImplementation(method), to: PerformActionIMP.self)
        let hook: @convention(block) (AnyObject, AnyObject) -> Bool = { node, action in
            guard (action as? String) == scrollToEndAction else {
                return original(node, selector, action)
            }
            // 辅助功能动作由 AppKit 在主线程派发；万一不是，宁可报失败也不去碰视图。
            guard Thread.isMainThread else { return false }
            nonisolated(unsafe) let node = node
            return MainActor.assumeIsolated {
                scrollToEnd(from: node)
            }
        }
        method_setImplementation(method, imp_implementationWithBlock(hook))
    }

    private static func ownInstanceMethod(of cls: AnyClass, selector: Selector) -> Method? {
        var count: UInt32 = 0
        guard let methods = class_copyMethodList(cls, &count) else { return nil }
        defer { free(methods) }
        for index in 0..<Int(count) where method_getName(methods[index]) == selector {
            return methods[index]
        }
        return nil
    }

    @MainActor
    private static func scrollToEnd(from node: AnyObject) -> Bool {
        guard let scrollView = enclosingScrollView(of: node) else {
            lazyStackAccessibilityLog.info("AXScrollToBottom on lazy stack ignored: no enclosing scroll view")
            return false
        }
        scrollToEnd(scrollView, remainingPasses: settlePasses)
        return true
    }

    /// 节点的辅助功能父级一路往上，碰到的第一个 AppKit 视图就是承载它的滚动视图
    /// （实测直接就是 `HostingScrollView`）；不是的话取它所在的滚动视图。
    @MainActor
    private static func enclosingScrollView(of node: AnyObject) -> NSScrollView? {
        var current = accessibilityParent(of: node)
        for _ in 0..<64 {
            guard let object = current else { return nil }
            if let view = object as? NSView {
                return view as? NSScrollView ?? view.enclosingScrollView
            }
            current = accessibilityParent(of: object)
        }
        return nil
    }

    /// 这个私有节点类没有声明遵循 `NSAccessibilityProtocol`，只能按选择子问。
    private static func accessibilityParent(of object: AnyObject) -> AnyObject? {
        let selector = NSSelectorFromString("accessibilityParent")
        guard let object = object as? NSObject, object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @MainActor
    private static func scrollToEnd(_ scrollView: NSScrollView, remainingPasses: Int) {
        guard remainingPasses > 0, let document = scrollView.documentView else { return }
        let clipView = scrollView.contentView
        let visible = clipView.bounds
        let overflowsVertically = document.frame.height > visible.height + 0.5
        let overflowsHorizontally = document.frame.width > visible.width + 0.5
        guard overflowsVertically || overflowsHorizontally else { return }

        // 目标先放到极远处，交给剪辑视图按文档范围和内容边距收回来。
        let far = CGFloat(1e7)
        var target = visible
        if overflowsVertically {
            target.origin.y = document.isFlipped ? far : -far
        } else {
            target.origin.x = far
        }
        let end = clipView.constrainBoundsRect(target).origin
        if end != visible.origin {
            clipView.scroll(to: end)
            scrollView.reflectScrolledClipView(clipView)
        }

        let documentSize = document.frame.size
        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak scrollView] in
            MainActor.assumeIsolated {
                guard let scrollView, scrollView.documentView?.frame.size != documentSize else { return }
                scrollToEnd(scrollView, remainingPasses: remainingPasses - 1)
            }
        }
    }
}
#endif
