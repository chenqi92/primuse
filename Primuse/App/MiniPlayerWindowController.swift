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
///   1. 内容用顶层 `contentView = NSHostingView`,并让 NSHostingView 按
///      MacMiniPlayerView 自己钉死的 .frame 决定窗口尺寸(顶层 hosting view
///      的这个行为关不掉,索性反过来利用它);若嵌进哑容器规避,SwiftUI 会
///      拿不到尺寸提议、内容塌成空白。
///   2. `isReleasedWhenClosed = false` 否则关一次窗口控制器对象 deinit。
///   3. `level = .floating` + `.fullScreenAuxiliary` collectionBehavior,
///      让 mini player 在主窗口全屏时仍能出现在同一 Space。
///   4. `NSApp.activate(ignoringOtherApps: true)` 确保非前台时也能弹出。
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate {
    @AppStorage("miniPlayerVisible") private var visible: Bool = false

    /// 折叠态 (无歌词/队列面板) 的窗口高度,刚好够装封面 + 标题 + 进度;
    /// 展开态拉到 expandedHeight 让传输键 + 面板有足够空间。MacMiniPlayerView
    /// 直接读这几个常量,把内容 fitting size 钉成同一尺寸,所以非 private。
    static let collapsedHeight: CGFloat = 220
    static let expandedHeight: CGFloat = 540
    /// 设计稿里迷你播放器是固定 300pt 宽的长条,不允许用户拉伸宽度——
    /// 否则布局会被撑成一大片(用户反馈过"打开就是很宽的一块")。
    static let fixedWidth: CGFloat = 300

    /// NSHostingView 实例 —— 持有它防止 SwiftUI rootView 被回收。
    /// 用基类 NSView,因为 NSHostingView 是泛型,没法直接做 stored property 类型。
    private var hostingView: NSView?

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.collapsedHeight),
            // 不带 .resizable —— 宽度恒定、高度只在折叠/展开两个值之间由
            // controller 程序化切换,不让用户拖拽改尺寸。
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.isMovableByWindowBackground = true
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { type in
            win.standardWindowButton(type)?.isHidden = true
        }
        win.level = .floating
        win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        win.isReleasedWhenClosed = false
        // 宽度锁死在 fixedWidth(min == max),高度允许在折叠/展开之间变化。
        win.minSize = NSSize(width: Self.fixedWidth, height: Self.collapsedHeight)
        win.maxSize = NSSize(width: Self.fixedWidth, height: Self.expandedHeight)
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
        // 后续打开自动 restore 用户拖过的位置。尺寸的归一化放到下面
        // contentViewController 赋值之后做,因为 NSHostingController 会
        // 反过来改写 window 尺寸,必须在它之后再钉一次。
        // 清掉早期可拉伸 / broken 版本存进 defaults 的过大 frame(实测残留过
        // 720×752),否则 setFrameAutosaveName 每次都会把它 restore 回来,盖过
        // 设计尺寸,表现为"迷你播放器一打开就是一大片"。
        win.setFrameAutosaveName("")
        NSWindow.removeFrame(usingName: "PrimuseMiniPlayer")
        win.setFrameAutosaveName("PrimuseMiniPlayer")

        self.init(window: win)

        // 顶层 NSHostingView 一定会按 SwiftUI 内容的 fitting size 决定窗口大小
        // (实测无论 sizingOptions / contentViewController 怎么设都关不掉;之前
        // MacMiniPlayerView 里的 ScrollView fitting 无上界,把窗口撑成 720×752)。
        // 嵌进哑 NSView 容器虽能挡住撑大,但会让 SwiftUI 拿不到尺寸提议、root
        // VStack 塌成 0,内容只剩背景一片灰。
        // 所以反过来利用这个行为:MacMiniPlayerView 已经把自己的 fitting size 用
        // .frame 钉成 300×220(折叠) / 300×540(展开),hostingView 直接做顶层
        // contentView,窗口就正好是这个尺寸,既渲染正常又不会被撑大。
        // onBottomModeChange 里同步把窗口高度动画到目标值并保持顶端不动。
        let hostingView = NSHostingView(
            rootView: MacMiniPlayerView(
                onClose: { [weak self] in self?.hide() },
                onBottomModeChange: { [weak self] mode in
                    self?.resize(forMode: mode)
                }
            )
            .applyPrimuseEnvironments()
        )
        hostingView.translatesAutoresizingMaskIntoConstraints = true
        hostingView.autoresizingMask = [.width, .height]
        hostingView.frame = win.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.collapsedHeight)
        self.hostingView = hostingView
        win.contentView = hostingView
        win.delegate = self

        // 内容区接好后再把尺寸钉死回设计值,只保留 restore 出来的屏幕位置,
        // 兜住 autosave 残留的过宽 / 过高 frame。
        win.minSize = NSSize(width: Self.fixedWidth, height: Self.collapsedHeight)
        win.maxSize = NSSize(width: Self.fixedWidth, height: Self.expandedHeight)
        win.setFrame(
            NSRect(origin: win.frame.origin,
                   size: NSSize(width: Self.fixedWidth, height: Self.collapsedHeight)),
            display: false
        )

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
        // 宽度恒定 fixedWidth;collapsedHeight / expandedHeight 都落在
        // [minSize, maxSize] 区间内,直接动画到目标高度即可,不必再动
        // minSize(早期为绕开 clamp 临时调 minSize 反而引入过 bug)。
        let newFrame = NSRect(
            x: current.origin.x,
            y: current.origin.y - delta,
            width: Self.fixedWidth,
            height: target
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
