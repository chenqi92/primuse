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

        // 跟 macOS 设置窗口同款:只保留关闭红灯,黄灯 (最小化) 和绿灯
        // (缩放) 灰掉。styleMask 不带 .miniaturizable / .resizable 系统
        // 自动把那两个按钮置灰,窗口尺寸也固定不能拖边缘缩放。
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        win.title = String(localized: "scrape_song")
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
#endif
