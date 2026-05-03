#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// Borderless transparent NSPanel that floats over every other window. The
/// SwiftUI content (`DesktopLyricsView`) re-fetches lyrics on song change and
/// follows playback time. Position is persisted via the panel's auto-save
/// frame name so users only have to drag it once per screen layout.
@MainActor
final class DesktopLyricsWindowController {
    private var panel: NSPanel?
    @AppStorage("desktopLyricsVisible") private var visible: Bool = false
    @AppStorage("desktopLyricsLocked") private var locked: Bool = false

    /// 横向布局 (single/dual) 默认尺寸 —— 参考主流桌面歌词软件的宽度
    /// 习惯 (网易云 / QQ 音乐 / LyricsX 都是屏幕宽度 60-75%):跟随主屏
    /// visibleFrame 宽度的 70%,clamp 到 [900, 1400]。短边 (height) 固定
    /// 260pt,这是因为顶部工具栏整合了 10 个按钮 (上一首/播放/下一首/排
    /// 版/背景/颜色/字号-/字号+/锁定/关闭),最少需要 ~250pt 宽度,260pt
    /// 给纵向模式 (width = 260) 留出余量。
    private static var horizontalSize: NSSize {
        let screenWidth = NSScreen.main?.visibleFrame.width ?? 1440
        let longSide = max(900, min(1400, screenWidth * 0.7))
        return NSSize(width: longSide, height: 260)
    }

    /// 纵向布局默认尺寸 —— 跟横向尺寸"长宽对调",但 height 还要再
    /// clamp 到屏可见区域的 85% 以内,免得长条延伸到屏幕外把底部按钮
    /// 顶到 dock 下面点不到。屏幕短的笔记本 (13/14 寸 1080p) 上长边可
    /// 能从 1400pt 缩到 ~700pt,这是预期的。
    private static var verticalSize: NSSize {
        let h = horizontalSize
        let screenHeight = NSScreen.main?.visibleFrame.height ?? 900
        let maxAllowed = screenHeight * 0.85
        return NSSize(width: h.height, height: min(h.width, maxAllowed))
    }

    init() {
        if visible { show() }
        // 监听 lock 变化（来自菜单栏 popover 或桌面歌词的悬浮 toolbar）
        // 同步给 NSPanel,因为 ignoresMouseEvents 是 NSWindow 级别状态。
        NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.applyLockedState() }
        }
    }

    func toggle() {
        if panel?.isVisible == true { hide() } else { show() }
    }

    func show() {
        let panel: NSPanel
        if let existing = self.panel {
            panel = existing
        } else {
            panel = makePanel()
            self.panel = panel
        }
        panel.orderFrontRegardless()
        visible = true
        applyLockedState()
    }

    func hide() {
        panel?.orderOut(nil)
        visible = false
    }

    /// 用户切换排版时把 panel 拉成对应朝向。围绕中心点缩放,避免
    /// 从某个角"长"出来视觉跳变。如果用户已经手动拖到接近目标尺寸
    /// (可能他自己定的),不强行覆盖。
    private func applyLayoutSize(_ layout: DesktopLyricsLayout) {
        guard let panel else { return }
        let target: NSSize
        switch layout {
        case .single, .dual: target = Self.horizontalSize
        case .vertical: target = Self.verticalSize
        }
        let current = panel.frame
        // 已经接近就不动 —— 用户可能拖过自定义尺寸,不要每次切排版
        // 都把人家辛苦调好的尺寸抹掉。
        if abs(current.width - target.width) < 60,
           abs(current.height - target.height) < 60 {
            return
        }
        let center = NSPoint(x: current.midX, y: current.midY)
        let newFrame = NSRect(
            x: center.x - target.width / 2,
            y: center.y - target.height / 2,
            width: target.width,
            height: target.height
        )
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.28
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(newFrame, display: true)
        }
    }

    private func applyLockedState() {
        // 锁定时:
        //   - 不再设 ignoresMouseEvents=true,否则 SwiftUI 收不到 hover,
        //     用户没法在 panel 上 hover 出解锁按钮。
        //   - 关掉 isMovableByWindowBackground 防止误拖。
        //   - 解锁路径:hover 浮现的锁按钮 / 菜单栏开关 / ⇧⌘L 快捷键。
        // 直接读 UserDefaults 而不是 @AppStorage 包装,因为这个类不是
        // SwiftUI View,@AppStorage 的"自动跟随"在非 View 上下文里
        // 不一定每次都拿到最新值。
        let isLocked = UserDefaults.standard.bool(forKey: "desktopLyricsLocked")
        panel?.ignoresMouseEvents = false
        panel?.isMovableByWindowBackground = !isLocked
    }

    private func makePanel() -> NSPanel {
        // .resizable + .borderless 让 panel 没有标题条但仍可从四边
        // 拖拽改尺寸。SwiftUI 内部 GeometryReader 会按新尺寸刷新字号。
        let initial = Self.horizontalSize
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 80, width: initial.width, height: initial.height),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 90, height: 70)
        // autosave name 带 v2 后缀:之前默认 600x140 太窄会截断长歌词,
        // 改默认值时换 key 让老用户也跳到新的宽默认值,而不是停在旧
        // 持久化的 600pt 上看 ... 截断。
        panel.setFrameAutosaveName("PrimuseDesktopLyrics_v2")

        let host = NSHostingController(
            rootView: DesktopLyricsView(
                onClose: { [weak self] in self?.hide() },
                onLayoutChange: { [weak self] layout in
                    self?.applyLayoutSize(layout)
                }
            ).applyPrimuseEnvironments()
        )
        host.view.frame = panel.contentView?.bounds ?? .zero
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view

        // 默认横向居中、贴 Dock 上方;v2 autosave 没保存过 frame 时
        // (origin == .zero) 走这条路径,保存过就跟随用户上次拖到的位置。
        if let screen = NSScreen.main, panel.frame.origin == .zero {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(
                x: screen.visibleFrame.midX - frame.width / 2,
                y: screen.visibleFrame.minY + 80
            ))
        }
        return panel
    }
}
#endif
