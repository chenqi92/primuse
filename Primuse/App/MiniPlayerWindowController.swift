#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 常驻 floating 的迷你播放器窗口,Apple Music 的「迷你播放程序」等价物。
/// 关闭只是 hide,下次还能用同一个 controller 再 show 出来。
///
/// 关键点(都是踩过的坑):
///   1. 用无边框 `NSPanel` 而非 `.titled` 窗口:`.titled` 会在内容高度上叠加
///      ~32pt 标题栏,做不到设计稿精确的 300×220 / 300×540;无边框下窗口尺寸
///      == 内容尺寸,正好对齐。圆角 / 阴影由宿主 layer 裁切 + 窗口 clear 背景
///      + `hasShadow` 实现。
///   2. `contentView = host.view`(NSHostingController 的 view)+ `wantsLayer`:
///      无边框 + clear 背景下,不开 wantsLayer 内容画不出来(整片透明)。
///   3. 内容(MacMiniPlayerView)绝对不能用带 `.drawingGroup()` 的 AmbientBackdrop
///      做背景 —— drawingGroup 会把 ZStack 的兄弟层(主内容)整组渲染掉,只剩背景
///      (就是"空白卡片"的根因)。已改用简单不透明渐变背景。
///   4. 窗口负责高度动画,内容跟随宿主尺寸;展开时按屏幕剩余空间选择固定边。
///   5. `isReleasedWhenClosed = false`;`level = .floating` + `.fullScreenAuxiliary`。
@MainActor
final class MiniPlayerWindowController: NSWindowController, NSWindowDelegate {
    @AppStorage("miniPlayerVisible") private var visible: Bool = false

    /// 折叠态(无歌词/队列面板)高度 —— 设计稿 NP-Mini 标 300×220, 但实际内容
    /// (顶栏 32 + 封面 76 + 标题 + 进度条 + 常驻 footer)约 237pt, 钉死 220 会让
    /// 整组内容居中溢出、顶部折叠/关闭按钮被窗口圆角裁掉。给到 240 让内容完整放下。
    static let collapsedHeight: CGFloat = 240
    static let expandedHeight: CGFloat = 540
    static let fixedWidth: CGFloat = 300

    /// 持有 hosting controller,保证 SwiftUI 内容存活、环境更新生效。
    private var hosting: NSViewController?
    private var expansionAnchor: NowPlayingInteractionPolicy.MiniPlayerExpansionAnchor = .top
    private var isExpanded = false

    convenience init() {
        let panel = MiniPlayerPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.collapsedHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.isMovableByWindowBackground = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // 显示/隐藏交给系统做淡入淡出, 它自己会照顾「减少动态效果」。
        panel.animationBehavior = .utilityWindow
        panel.minSize = NSSize(width: Self.fixedWidth, height: Self.collapsedHeight)
        panel.maxSize = NSSize(width: Self.fixedWidth, height: Self.expandedHeight)

        if let screen = NSScreen.main {
            let vr = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: vr.maxX - Self.fixedWidth - 40, y: vr.minY + 80))
        }
        panel.setFrameAutosaveName("PrimuseMiniPlayer")

        self.init(window: panel)

        let host = NSHostingController(
            rootView: MacMiniPlayerView(
                onClose: { [weak self] in self?.hide() },
                onBottomModeChange: { [weak self] mode in
                    self?.resize(forMode: mode)
                }
            )
            .applyPrimuseEnvironments()
        )
        self.hosting = host
        host.sizingOptions = []
        host.view.frame = panel.contentView?.bounds
            ?? NSRect(x: 0, y: 0, width: Self.fixedWidth, height: Self.collapsedHeight)
        host.view.autoresizingMask = [.width, .height]
        host.view.wantsLayer = true
        // 裁切边界跟随实际窗口,避免目标高度的 SwiftUI 圆角在缩放中被截成直角。
        host.view.layer?.cornerRadius = 14
        host.view.layer?.cornerCurve = .continuous
        host.view.layer?.masksToBounds = true
        panel.contentView = host.view
        panel.delegate = self

        // 精确钉到折叠态设计尺寸(只保留 restore 出来的屏幕位置)。
        panel.setFrame(
            NSRect(origin: panel.frame.origin,
                   size: NSSize(width: Self.fixedWidth, height: Self.collapsedHeight)),
            display: false
        )

        if visible { show() }
    }

    private func resize(forMode mode: MacMiniPlayerView.BottomMode) {
        guard let window else { return }
        let expands = mode != .none
        guard expands != isExpanded else { return }
        let current = window.frame
        let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame ?? current
        if expands {
            expansionAnchor = NowPlayingInteractionPolicy.miniPlayerExpansionAnchor(
                frame: current,
                expandedHeight: Self.expandedHeight,
                visibleFrame: visibleFrame
            )
        }
        isExpanded = expands
        let newFrame = NowPlayingInteractionPolicy.miniPlayerFrame(
            currentFrame: current,
            targetHeight: expands ? Self.expandedHeight : Self.collapsedHeight,
            visibleFrame: visibleFrame,
            anchor: expansionAnchor
        )
        guard current != newFrame else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            window.setFrame(newFrame, display: true)
            window.invalidateShadow()
            return
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            ctx.allowsImplicitAnimation = true
            window.animator().setFrame(newFrame, display: true)
        } completionHandler: { [weak window] in
            Task { @MainActor in
                window?.invalidateShadow()
            }
        }
    }

    func toggle() {
        if window?.isVisible == true { hide() } else { show() }
    }

    func show() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.invalidateShadow()
        plog("🎵 MiniPlayer.show() frame=\(window.frame)")
        visible = true
    }

    func hide() {
        window?.orderOut(nil)
        visible = false
    }

    // MARK: - NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        window?.invalidateShadow()
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.hide() }
        return false // 不销毁,只 hide
    }
}

/// 无边框迷你播放器面板。重写 `canBecomeKey` 让内部控件能正常交互;无 close
/// 按钮时 `performClose` 默认会 NSBeep,这里转交 delegate 的 `windowShouldClose`
/// (我们的实现只 hide),让自绘流量灯红灯也能关窗。
private final class MiniPlayerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func performClose(_ sender: Any?) {
        _ = delegate?.windowShouldClose?(self)
    }
}
#endif
