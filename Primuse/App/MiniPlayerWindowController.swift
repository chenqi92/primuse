#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 一个常驻 floating 状态的小型播放器窗口,Apple Music 的「迷你播放程序」
/// 等价物。继承 NSWindowController 是 Apple 文档里建议的标准模式
/// (https://developer.apple.com/documentation/appkit/nswindowcontroller),
/// 把 window 生命周期跟 controller 绑在一起,window 关闭只是 hide,下次
/// 还能用同一个 controller 把它再 show 出来。
///
/// 关键点(都是踩过的坑):
///   1. 用 `contentViewController` 而不是 `contentView` —— 后者会丢失
///      hosting controller 的 root view 布局,SwiftUI view 显示成空白。
///   2. `isReleasedWhenClosed = false` 否则关一次窗口控制器对象 deinit。
///   3. `level = .floating` + `.fullScreenAuxiliary` collectionBehavior,
///      让 mini player 在主窗口全屏时仍能出现在同一 Space。
///   4. `NSApp.activate(ignoringOtherApps: true)` 确保非前台时也能弹出。
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate {
    @AppStorage("miniPlayerVisible") private var visible: Bool = false

    /// 折叠态 (无歌词/队列面板) 的窗口高度,刚好够装工具条 + 进度条 +
    /// 传输键;展开态拉到 expandedHeight 让面板有足够滚动空间。
    private static let collapsedHeight: CGFloat = 220
    private static let expandedHeight: CGFloat = 540

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: Self.collapsedHeight),
            styleMask: [.titled, .closable, .fullSizeContentView, .resizable],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 280, height: Self.collapsedHeight)
        win.title = "Primuse Mini Player"

        // 第一次展示居中右下,跟 macOS 习惯的 mini 播放器位置一致。
        if let screen = NSScreen.main {
            let frame = win.frame
            let visibleRect = screen.visibleFrame
            win.setFrameOrigin(NSPoint(
                x: visibleRect.maxX - frame.width - 40,
                y: visibleRect.minY + 80
            ))
        }
        // autosave name 放在最后,这样首次定位用上面的居中右下,
        // 后续打开自动 restore 用户拖过的位置。
        win.setFrameAutosaveName("PrimuseMiniPlayer")

        self.init(window: win)

        // 用 contentViewController 才能让 SwiftUI hosting controller
        // 正确接管布局;直接 setContentView 会丢 hosting controller 的
        // root view tree,显示成空白。
        let host = NSHostingController(
            rootView: MacMiniPlayerView(
                onClose: { [weak self] in self?.hide() },
                onBottomModeChange: { [weak self] mode in
                    self?.resize(forMode: mode)
                }
            )
            .applyPrimuseEnvironments()
        )
        win.contentViewController = host
        win.delegate = self

        if visible { show() }
    }

    /// 切换 bottomMode 时把窗口高度拉到展开值或收回到折叠值。保持
    /// 顶端 (titlebar) 视觉位置不动,所以重新放置 origin.y 让差值
    /// 加在底边——否则窗口会从下边沿往上"长",在视觉上像翻车。
    /// 用 NSAnimationContext 替代 setFrame(animate:),时间曲线和时长
    /// 跟 SwiftUI 内 `.animation(.easeInOut(duration: 0.28))` 对齐,
    /// 两边一起动避免"窗口先 resize 完内容才补上"的钝感。
    private func resize(forMode mode: MacMiniPlayerView.BottomMode) {
        guard let window else { return }
        let target: CGFloat = mode == .none ? Self.collapsedHeight : Self.expandedHeight
        let current = window.frame
        guard abs(current.height - target) > 0.5 else { return }
        let delta = target - current.height
        let newFrame = NSRect(
            x: current.origin.x,
            y: current.origin.y - delta,
            width: current.width,
            height: target
        )
        // 先放宽 minSize,再动画到新尺寸 —— 反过来会被 minSize clamp 卡
        // 在缩小这步,setFrame 调小到 collapsedHeight 时立刻被 minSize=380
        // 顶回去,看起来像没反应。
        window.minSize = NSSize(
            width: window.minSize.width,
            height: mode == .none ? Self.collapsedHeight : 380
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(newFrame, display: true)
        }
    }

    func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        plog("🎵 MiniPlayer.show() visible=\(window.isVisible) level=\(window.level.rawValue) frame=\(window.frame)")
        visible = true
    }

    func hide() {
        window?.orderOut(nil)
        visible = false
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.hide() }
        return false // 不销毁,只 hide
    }
}
#endif
