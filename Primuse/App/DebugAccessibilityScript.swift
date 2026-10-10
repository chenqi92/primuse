#if DEBUG && os(macOS)
import AppKit
import ApplicationServices
import PrimuseKit

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
/// - `window:<宽>x<高>`：把主窗口改成这个尺寸（点）。
/// - `scroll:<y>`：把主窗口里最大的那个竖向滚动视图滚到 y。
/// - `route:<页面>`：主窗口换到这一页，写法同 `primuse.navigation.macRoute.v1`（home、section:albums…）。
/// - `open:album:<片段>` / `open:artist:<片段>` / `open:book:<片段>`：把名字含这一段（不分大小写）的第一张专辑、
///   第一位艺人、第一本有声书压进当前页的详情栈，和在页面里点进去走同一条通知。
/// - `snapshot:<png 路径>`：把主窗口内容离屏画成 PNG —— 锁屏时 screencapture 只拍得到壁纸。
/// - `layers`：按类名统计主窗口的图层树，系统私有类（背板、传送门、远端图层）逐个记下位置 ——
///   离屏截图某块画不出来时拿它找原因。
/// - `quit`：退出 App。
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
        case "window":
            resizeMainWindow(argument)
        case "scroll":
            scrollMainWindow(to: Double(argument) ?? 0)
        case "route":
            NotificationCenter.default.post(name: .primuseDebugSelectRoute, object: argument)
            plog("🧪 AX script: route -> \(argument)")
        case "open":
            openDetail(argument)
        case "snapshot":
            snapshotMainWindow(to: argument)
        case "layers":
            reportLayers()
        case "quit":
            NSApp.terminate(nil)
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
    private static func openDetail(_ argument: String) {
        let parts = argument.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            plog("🧪 AX script: open \(argument) skipped")
            return
        }
        let needle = parts[1].lowercased()
        let library = AppServices.shared.musicLibrary
        switch parts[0] {
        case "album":
            guard let album = library.visibleAlbums.first(where: { $0.title.lowercased().contains(needle) }) else { break }
            NotificationCenter.default.post(name: .primuseDetailOpenAlbum, object: album)
            plog("🧪 AX script: open album '\(album.title)'")
            return
        case "artist":
            guard let artist = library.visibleArtists.first(where: { $0.name.lowercased().contains(needle) }) else { break }
            NotificationCenter.default.post(name: .primuseDetailOpenArtist, object: artist)
            plog("🧪 AX script: open artist '\(artist.name)'")
            return
        case "book":
            let store = SpokenWordStore.shared
            let items = library.spokenWordSongs.map { SpokenWordBookSupport.item(for: $0, store: store) }
            guard let book = SpokenWordBookGrouping.books(from: items)
                .first(where: { $0.title.lowercased().contains(needle) }) else { break }
            NotificationCenter.default.post(name: .primuseDetailOpenSpokenWordBook, object: book.id)
            plog("🧪 AX script: open book '\(book.title)'")
            return
        default:
            break
        }
        plog("🧪 AX script: open \(argument) found nothing")
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
    private static var mainWindow: NSWindow? {
        NSApp.windows
            .filter { $0.isVisible && $0.styleMask.contains(.titled) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }
    }

    @MainActor
    private static func resizeMainWindow(_ argument: String) {
        let size = argument.split(separator: "x").compactMap { Double($0) }
        guard size.count == 2, let window = mainWindow else {
            plog("🧪 AX script: window \(argument) skipped")
            return
        }
        var frame = window.frame
        frame.size = NSSize(width: size[0], height: size[1])
        window.setFrame(frame, display: true)
        plog("🧪 AX script: window -> \(window.frame.size)")
    }

    @MainActor
    private static func scrollMainWindow(to y: Double) {
        guard let content = mainWindow?.contentView,
              let scrollView = scrollViews(in: content)
                .filter({ ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height })
                .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let document = scrollView.documentView else {
            plog("🧪 AX script: scroll found no vertical scroll view")
            return
        }
        let maxY = max(0, document.frame.height - scrollView.contentView.bounds.height)
        let target = min(max(0, y), maxY)
        scrollView.contentView.scroll(to: NSPoint(
            x: scrollView.contentView.bounds.origin.x,
            y: document.isFlipped ? target : maxY - target
        ))
        scrollView.reflectScrolledClipView(scrollView.contentView)
        plog("🧪 AX script: scroll -> \(target) of \(maxY)")
    }

    @MainActor
    private static func snapshotMainWindow(to path: String) {
        for window in NSApp.windows where window.isVisible {
            plog("🧪 AX script: window \(type(of: window)) '\(window.title)' frame=\(window.frame) key=\(window.isKeyWindow)")
        }
        guard let view = mainWindow?.contentView,
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            plog("🧪 AX script: snapshot found no window")
            return
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        do {
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            plog("🧪 AX script: snapshot \(view.bounds.size) -> \(path)")
        } catch {
            plog("🧪 AX script: snapshot failed \(error.localizedDescription)")
        }
    }

    @MainActor
    private static func reportLayers() {
        guard let root = mainWindow?.contentView?.layer else {
            plog("🧪 AX script: layers found no layer-backed window")
            return
        }
        var counts: [String: Int] = [:]
        var notable: [String] = []
        func walk(_ layer: CALayer, depth: Int) {
            let name = String(describing: type(of: layer))
            counts[name, default: 0] += 1
            // 背板、传送门、SDF(玻璃)、RenderBox 表面、远端图层这几类 renderInContext 画不出来。
            let offscreenOpaque = ["Backdrop", "Portal", "SDF", "RB", "Host", "Chameleon"]
                .contains { name.contains($0) }
            if offscreenOpaque, notable.count < 40 {
                let frame = layer.convert(layer.bounds, to: root)
                notable.append("\(name) depth=\(depth) frame=\(frame.integral) hidden=\(layer.isHidden) opacity=\(layer.opacity) filters=\(layer.filters?.count ?? 0)")
            }
            guard depth < 80 else { return }
            for sublayer in layer.sublayers ?? [] { walk(sublayer, depth: depth + 1) }
        }
        walk(root, depth: 0)
        plog("🧪 AX script: layers \(counts.sorted { $0.value > $1.value }.map { "\($0.key)×\($0.value)" }.joined(separator: " "))")
        for line in notable { plog("🧪 AX script: layer \(line)") }
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

extension Notification.Name {
    /// 调试脚本让主窗口换页，object 是页面的持久化写法。
    static let primuseDebugSelectRoute = Notification.Name("primuse.debug.selectRoute")
}
#endif
