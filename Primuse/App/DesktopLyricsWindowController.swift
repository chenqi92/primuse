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

    private func applyLockedState() {
        // 锁定时让 panel 不接收鼠标事件,点击穿透到下方应用。
        // 解锁路径:
        //   1) 菜单栏 popover 里的「桌面歌词锁定」开关
        //   2) 主窗口聚焦时按 ⇧⌘L
        // 直接读 UserDefaults 而不是 @AppStorage 包装,因为这个类不是
        // SwiftUI View,@AppStorage 的"自动跟随"在非 View 上下文里
        // 不一定每次都拿到最新值。
        let isLocked = UserDefaults.standard.bool(forKey: "desktopLyricsLocked")
        panel?.ignoresMouseEvents = isLocked
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 80, width: 600, height: 140),
            styleMask: [.borderless, .nonactivatingPanel],
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
        panel.setFrameAutosaveName("PrimuseDesktopLyrics")

        let host = NSHostingController(
            rootView: DesktopLyricsView(onClose: { [weak self] in
                self?.hide()
            }).applyPrimuseEnvironments()
        )
        host.view.frame = panel.contentView?.bounds ?? .zero
        host.view.autoresizingMask = [.width, .height]
        panel.contentView = host.view

        // Center horizontally, sit above the Dock the first time it's shown.
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
