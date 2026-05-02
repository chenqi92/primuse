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

    init() {
        if visible { show() }
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
    }

    func hide() {
        panel?.orderOut(nil)
        visible = false
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
            rootView: DesktopLyricsView().applyPrimuseEnvironments()
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
