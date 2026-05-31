#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// 把刮削元数据 sheet 改成独立 NSWindow 弹出 —— 走 macOS 标准 titled +
/// closable + resizable 窗口,用户能看到左上角红绿灯那一组系统原生窗
/// 口控件 (关闭/最小化/缩放),跟 macOS 26 设置/检查器面板风格一致。
///
/// 单例 + reuse window:每次 show() 重建 NSHostingController 让 SwiftUI
/// 状态从干净的 options 级开始,避免用户开第二次 sheet 仍停在上次的
/// preview 级。
@MainActor
final class ScrapeWindowController: NSObject, NSWindowDelegate {
    static let shared = ScrapeWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// 打开刮削窗口。已经打开的窗口直接换内容并 makeKey。
    func show(song: Song, onComplete: ((Song) -> Void)? = nil) {
        let host = makeHost(song: song, onComplete: onComplete)
        if let win = window {
            win.contentViewController = host
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "scrape_song")
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.toolbar = nil
        win.backgroundColor = .clear
        // 兜底最小尺寸, 防止 autosave 还原出一个过窄的窗口把三栏挤裂
        // (三栏硬最小宽 ≈ 906, 取 920 留点余量)。
        win.minSize = NSSize(width: 920, height: 560)
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { type in
            win.standardWindowButton(type)?.isHidden = true
        }
        win.center()
        win.setFrameAutosaveName("PrimuseScrapeOptions")
        // isReleasedWhenClosed=false + delegate.windowShouldClose 让窗口
        // 在用户点红灯后只 hide 不释放,保留 window 引用以便下次复用。
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.delegate = self
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    /// 主动关闭 (SwiftUI 内 applySelectedChanges 后会通过 onCloseRequest
    /// 触发到这里)。
    func close() {
        window?.orderOut(nil)
    }

    private func makeHost(song: Song, onComplete: ((Song) -> Void)?) -> NSViewController {
        let view = ScrapeOptionsView(
            song: song,
            onComplete: onComplete,
            onCloseRequest: { [weak self] in self?.close() }
        )
        .applyPrimuseEnvironments()
        return NSHostingController(rootView: view)
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.window?.orderOut(nil) }
        return false // 不真正销毁,只 hide,下次 show() 复用 window
    }
}

/// 设置窗口 —— 用独立 NSWindow 而不是 SwiftUI `Settings {}` scene。
///
/// SwiftUI 的 `Settings` scene 会强制一个原生标题栏 (`.windowStyle(.hiddenTitleBar)`
/// 对它无效), 把我们按设计稿自绘的标题栏 (三色灯 / ‹ › / 居中标题) 顶到原生白条
/// 下面盖住。改用 fullSizeContentView + 透明标题栏 + 隐藏系统按钮的自定义窗口,
/// 跟主窗口、刮削窗口同一套 chrome, 自绘标题栏才能铺到窗口最顶。
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private var window: NSWindow?

    private override init() { super.init() }

    /// 打开设置窗口 (Cmd+, / 菜单触发)。已开则置前。
    func show() {
        if let win = window {
            NSApp.activate(ignoringOtherApps: true)
            win.makeKeyAndOrderFront(nil)
            return
        }

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.toolbar = nil
        win.backgroundColor = .clear
        win.minSize = NSSize(width: 940, height: 680)
        [
            NSWindow.ButtonType.closeButton,
            .miniaturizeButton,
            .zoomButton,
        ].forEach { win.standardWindowButton($0)?.isHidden = true }
        win.center()
        win.setFrameAutosaveName("PrimuseSettings")
        win.isReleasedWhenClosed = false
        win.contentViewController = NSHostingController(
            rootView: MacSettingsView().applyPrimuseEnvironments()
        )
        win.delegate = self
        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor in self.window?.orderOut(nil) }
        return false
    }
}
#endif
