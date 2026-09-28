#if DEBUG && os(macOS)
import AppKit
import ApplicationServices

/// 在进程内按脚本执行辅助功能动作，给编译机上无人值守地复测界面用。
///
/// 编译机屏幕常年锁着，外部辅助功能客户端这时只看得到菜单栏、看不到窗口内容，
/// 所以动作只能从进程里发：先以客户端身份问自己一次，让 SwiftUI 把辅助功能树建出来，
/// 再遍历窗口的辅助功能元素，在主线程运行循环上直接调用它们的动作 —— 与 AppKit
/// 收到外部请求后的派发方式相同，不在任何视图更新里。
///
/// `PRIMUSE_DEBUG_AX_SCRIPT="wait:8;scrollend;wait:2;report"`，步骤用分号隔开：
/// - `wait:<秒>`：等待。
/// - `playlist:<歌单名>`：等曲库装好，把全部音乐建成（或沿用）这个名字的歌单，
///   并把 Mac 主窗口下次启动恢复的页面设成它。
/// - `scrollend` / `scrolltop`：对所有暴露 `AXScrollToBottom` / `AXScrollToTop` 的元素执行该动作。
/// - `report`：记下窗口里每个滚动视图的位置与文档尺寸。
/// 每一步都写 🧪 日志。
enum DebugAccessibilityScript {
    @MainActor
    static func runIfRequested() {
        guard let script = ProcessInfo.processInfo.environment["PRIMUSE_DEBUG_AX_SCRIPT"],
              !script.isEmpty else { return }
        let steps = script.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        plog("🧪 AX script: \(steps)")
        Task { @MainActor in
            for step in steps {
                await run(step)
            }
            plog("🧪 AX script: done")
        }
    }

    @MainActor
    private static func run(_ step: String) async {
        let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "wait":
            try? await Task.sleep(for: .seconds(Double(argument) ?? 1))
        case "playlist":
            await preparePlaylist(named: argument)
        case "scrollend":
            await perform("AXScrollToBottom")
        case "scrolltop":
            await perform("AXScrollToTop")
        case "report":
            report()
        default:
            plog("🧪 AX script: unknown step \(step)")
        }
    }

    @MainActor
    private static func preparePlaylist(named name: String) async {
        let library = AppServices.shared.musicLibrary
        for _ in 0..<120 where !library.isReady || library.musicSongs.isEmpty {
            try? await Task.sleep(for: .seconds(1))
        }
        let songIDs = library.musicSongs.map(\.id)
        let playlist = library.playlists.first(where: { $0.name == name })
            ?? library.createPlaylist(name: name, songIDs: songIDs)
        UserDefaults.standard.set("playlist:\(playlist.id)", forKey: "primuse.navigation.macRoute.v1")
        plog("🧪 AX script: playlist '\(name)' id=\(playlist.id) songs=\(library.songs(forPlaylist: playlist.id).count)")
    }

    @MainActor
    private static func perform(_ action: String) async {
        await connectAccessibilityClient()
        var targets: [NSObject] = []
        for window in NSApp.windows where window.isVisible {
            collect(window, action: action, depth: 0, into: &targets)
        }
        plog("🧪 AX script: \(targets.count) element(s) expose \(action)")
        let selector = NSSelectorFromString("accessibilityPerformAction:")
        for target in targets {
            typealias PerformAction = @convention(c) (NSObject, Selector, NSString) -> Bool
            let handled = unsafeBitCast(target.method(for: selector), to: PerformAction.self)(target, selector, action as NSString)
            plog("🧪 AX script: \(action) on \(type(of: target)) returned \(handled)")
        }
    }

    /// SwiftUI 只在有辅助功能客户端连上后才建辅助功能树。从后台线程以客户端身份把自己的窗口
    /// 走一遍（主线程这时空着，能应答），树就建好了。
    @MainActor
    private static func connectAccessibilityClient() async {
        let pid = getpid()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                let application = AXUIElementCreateApplication(pid)
                var windows: CFTypeRef?
                AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &windows)
                for window in (windows as? [AXUIElement]) ?? [] {
                    touch(window, depth: 0)
                }
                continuation.resume()
            }
        }
        try? await Task.sleep(for: .milliseconds(500))
    }

    private static func touch(_ element: AXUIElement, depth: Int) {
        guard depth < 24 else { return }
        var children: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children)
        for child in (children as? [AXUIElement]) ?? [] {
            touch(child, depth: depth + 1)
        }
    }

    @MainActor
    private static func collect(_ element: Any, action: String, depth: Int, into targets: inout [NSObject]) {
        guard depth < 48, let object = element as? NSObject else { return }
        if let names = send("accessibilityActionNames", to: object) as? [String], names.contains(action) {
            targets.append(object)
        }
        for child in (send("accessibilityChildren", to: object) as? [Any]) ?? [] {
            collect(child, action: action, depth: depth + 1, into: &targets)
        }
    }

    /// SwiftUI 的辅助功能节点不声明遵循 `NSAccessibilityProtocol`，只能按选择子问。
    private static func send(_ selectorName: String, to object: NSObject) -> Any? {
        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    @MainActor
    private static func report() {
        for window in NSApp.windows where window.isVisible {
            guard let content = window.contentView else { continue }
            for scrollView in scrollViews(in: content) {
                guard let document = scrollView.documentView else { continue }
                let visible = scrollView.contentView.bounds
                let end = scrollView.contentView.constrainBoundsRect(
                    NSRect(origin: NSPoint(x: 1e7, y: document.isFlipped ? 1e7 : -1e7), size: visible.size)
                ).origin
                plog("🧪 AX script: scroll view \(type(of: scrollView)) origin=\(visible.origin) visible=\(visible.size) document=\(document.frame.size) end=\(end)")
            }
        }
    }

    @MainActor
    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        var found: [NSScrollView] = []
        if let scrollView = view as? NSScrollView, scrollView.documentView != nil {
            found.append(scrollView)
        }
        for subview in view.subviews {
            found += scrollViews(in: subview)
        }
        return found
    }
}
#endif
