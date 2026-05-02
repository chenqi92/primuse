#if os(macOS)
import AppKit
import SwiftUI
import PrimuseKit

/// Owns the menu bar status item and its popover. Survives for the lifetime
/// of the app — the popover view is rebuilt on demand so SwiftUI sees fresh
/// observable state every time the user opens it.
@MainActor
final class MacMenuBarController: NSObject, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "Primuse")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover(_:))
        }
        self.statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.animates = true
        pop.contentSize = NSSize(width: 320, height: 360)
        pop.delegate = self
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPlayerView(onOpenMainWindow: { [weak self] in
                self?.activateMainWindow()
                self?.popover?.performClose(nil)
            })
            .applyPrimuseEnvironments()
        )
        self.popover = pop
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func activateMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain && !($0.styleMask.contains(.utilityWindow)) }) {
            window.makeKeyAndOrderFront(nil)
        }
    }
}

/// Helper to mirror the same environment objects PrimuseApp injects into
/// the main scene, so the popover view sees the same services.
extension View {
    func applyPrimuseEnvironments() -> some View {
        let services = AppServices.shared
        // No global tint here: same reasoning as PrimuseApp.injectServices
        // — macOS ships native control colors, the brand purple only
        // belongs on hand-styled brand surfaces.
        return self
            .environment(services.themeService)
            .environment(services.playerService)
            .environment(services.playerService.audioEngine)
            .environment(services.playerService.equalizerService)
            .environment(services.playerService.audioEffectsService)
            .environment(services.musicLibrary)
            .environment(services.sourcesStore)
            .environment(services.sourceManager)
            .environment(services.scraperSettingsStore)
            .environment(services.scraperService)
            .environment(services.playbackSettingsStore)
            .environment(services.scanService)
            .environment(services.cloudSync)
            .environment(services.metadataBackfill)
    }
}
#endif
