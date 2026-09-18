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
    /// didChangeNotification observer token —— 必须持有并在 deinit 注销, 否则
    /// block-based observer 永远不会移除 (内存泄漏)。nonisolated(unsafe): 仅 init
    /// (MainActor) 写、deinit 读, 无并发竞争, 让 Swift 6 的 nonisolated deinit 可访问。
    nonisolated(unsafe) private var lockObserver: NSObjectProtocol?
    /// 上次已应用的 lock 值 —— 全局 didChange 会因 app 内任何 UserDefaults 写入
    /// (音量/主题等高频) 触发, 只在 lock 真正变化时才动 panel, 避免主线程噪声。
    private var lastKnownLocked: Bool = false

    /// autosave name 带 v2 后缀:之前默认 600x140 太窄会截断长歌词,
    /// 改默认值时换 key 让老用户也跳到新的宽默认值,而不是停在旧
    /// 持久化的 600pt 上看 ... 截断。
    private static let frameAutosaveName = "PrimuseDesktopLyrics_v2"

    /// 一次拖动的起点:按下瞬间的鼠标屏幕坐标 + panel 当时的原点。
    /// 每个拖动事件都按"当前鼠标 - 起点鼠标"算绝对位移,而不是累加
    /// SwiftUI 给的 translation —— panel 是跟着手一起走的,窗口坐标系
    /// 里的位移每次都被自身的移动抵消回去,累加的写法会让窗口抖在原地。
    private var dragAnchor: (mouse: NSPoint, origin: NSPoint)?

    /// 直接读 UserDefaults 而不是 @AppStorage 包装,因为这个类不是
    /// SwiftUI View,@AppStorage 的"自动跟随"在非 View 上下文里
    /// 不一定每次都拿到最新值。
    private var isLockedNow: Bool {
        UserDefaults.standard.bool(forKey: "desktopLyricsLocked")
    }

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
        lastKnownLocked = locked
        // 监听 lock 变化（来自菜单栏 popover 或桌面歌词的悬浮 toolbar）
        // 同步给 NSPanel,因为 ignoresMouseEvents 是 NSWindow 级别状态。
        lockObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.locked != self.lastKnownLocked else { return }
                self.lastKnownLocked = self.locked
                self.applyLockedState()
            }
        }
    }

    deinit {
        if let lockObserver {
            NotificationCenter.default.removeObserver(lockObserver)
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
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.setFrame(newFrame, display: true)
            return
        }
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
        //   - 拖动由 updateWindowDrag 按锁定态拦掉,防止误拖。
        //   - 解锁路径:hover 浮现的锁按钮 / 菜单栏开关 / ⇧⌘L 快捷键。
        panel?.ignoresMouseEvents = false
        // 拖动过程中被锁上就把这次拖动作废,免得松手前还继续跟手。
        if isLockedNow { dragAnchor = nil }
    }

    // MARK: - 窗口拖动

    /// 桌面歌词的拖动自己做,不再交给 NSWindow.isMovableByWindowBackground ——
    /// panel 的 contentView 是 SwiftUI 的承载视图,它会把背景区域的 mouseDown
    /// 一并吃掉,AppKit 那条"点背景拖窗口"的路径就再也拿不到事件 (macOS 27 上
    /// 表现为解锁状态下歌词完全拖不动,只能待在初始位置)。改由 SwiftUI 侧识别
    /// 拖拽手势、这里直接搬 panel,行为在各版本 macOS 上都一致。
    /// 锁定时直接不动,菜单栏/悬浮锁按钮解锁后才恢复。
    private func updateWindowDrag() {
        guard let panel, !isLockedNow else { return }
        // 第一帧只记锚点:锚点同时取"此刻的鼠标位置"和"此刻的窗口原点",
        // 之后的位移都相对这一刻算,所以起手不会有跳一下的偏移。
        guard let anchor = dragAnchor else {
            dragAnchor = (NSEvent.mouseLocation, panel.frame.origin)
            return
        }
        let mouse = NSEvent.mouseLocation
        panel.setFrameOrigin(NSPoint(
            x: anchor.origin.x + (mouse.x - anchor.mouse.x),
            y: anchor.origin.y + (mouse.y - anchor.mouse.y)
        ))
    }

    private func endWindowDrag() {
        guard dragAnchor != nil else { return }
        dragAnchor = nil
        // setFrameOrigin 是代码改的 frame,不会触发 autosave 的自动落盘,
        // 松手时显式存一次,下次打开才回到用户拖好的位置。
        panel?.saveFrame(usingName: Self.frameAutosaveName)
    }

    /// 存下来的 frame 可能整块落在屏幕外 (拔掉外接屏、换分辨率、显示器重新排列),
    /// 那样窗口就"打开了但看不见"。只要和任何一块屏的可见区域都不相交就挪回主屏。
    private func moveOnScreenIfNeeded(_ panel: NSPanel) {
        let frame = panel.frame
        guard !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        applyDefaultOrigin(panel)
    }

    /// 默认位置:横向居中、贴 Dock 上方。
    private func applyDefaultOrigin(_ panel: NSPanel) {
        guard let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame else { return }
        let frame = panel.frame
        panel.setFrameOrigin(NSPoint(
            x: visible.midX - frame.width / 2,
            y: visible.minY + 80
        ))
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
        // 拖动改由 updateWindowDrag 负责,这里保持关闭:
        // 两条路径同时生效会把同一次拖动算两遍,窗口跑得比鼠标快一倍。
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.minSize = NSSize(width: 90, height: 70)
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        // setFrameAutosaveName 只登记"以后自动存",不会把上次存的 frame 读回来
        // (读是 setFrameUsingName 的事)。少了这一步,每次开桌面歌词都回到
        // contentRect 给的 (0, 80) —— 也就是屏幕左下角偏上一点点,用户上次
        // 拖到哪全白费。
        if panel.setFrameUsingName(Self.frameAutosaveName) {
            moveOnScreenIfNeeded(panel)
        } else {
            applyDefaultOrigin(panel)
        }

        let host = NSHostingController(
            rootView: DesktopLyricsView(
                onClose: { [weak self] in self?.hide() },
                onLayoutChange: { [weak self] layout in
                    self?.applyLayoutSize(layout)
                },
                onWindowDragChanged: { [weak self] in self?.updateWindowDrag() },
                onWindowDragEnded: { [weak self] in self?.endWindowDrag() }
            ).applyPrimuseEnvironments()
        )
        host.view.frame = panel.contentView?.bounds ?? .zero
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view
        return panel
    }
}
#endif
