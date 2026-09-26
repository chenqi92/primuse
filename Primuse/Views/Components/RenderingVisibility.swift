import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Scene activity alone does not describe visibility of secondary Mac windows.
    func onRenderingVisibilityChange(_ action: @escaping (Bool) -> Void) -> some View {
        modifier(RenderingVisibilityModifier(action: action))
    }
}

private struct RenderingVisibilityModifier: ViewModifier {
    let action: (Bool) -> Void
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        #if os(macOS)
        content.background(MacRenderingVisibilityObserver(action: action))
        #else
        content
            .onAppear { action(scenePhase == .active) }
            .onChange(of: scenePhase) { _, phase in action(phase == .active) }
            .onDisappear { action(false) }
        #endif
    }
}

#if os(macOS)
private struct MacRenderingVisibilityObserver: NSViewRepresentable {
    let action: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        VisibilityView(action: action)
    }

    func updateNSView(_ nsView: VisibilityView, context: Context) {
        nsView.action = action
        nsView.scheduleUpdate()
    }

    final class VisibilityView: NSView {
        var action: (Bool) -> Void
        private var lastValue: Bool?
        private var updatePending = false

        init(action: @escaping (Bool) -> Void) {
            self.action = action
            super.init(frame: .zero)
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification,
                         NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(visibilityChanged(_:)), name: name, object: nil)
            }
            NSWorkspace.shared.notificationCenter.addObserver(
                self, selector: #selector(visibilityChanged(_:)),
                name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
            )
        }

        required init?(coder: NSCoder) { return nil }

        deinit {
            NotificationCenter.default.removeObserver(self)
            NSWorkspace.shared.notificationCenter.removeObserver(self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            scheduleUpdate()
        }

        override func viewDidHide() { super.viewDidHide(); scheduleUpdate() }
        override func viewDidUnhide() { super.viewDidUnhide(); scheduleUpdate() }

        @objc private func visibilityChanged(_ notification: Notification) {
            if let changedWindow = notification.object as? NSWindow, changedWindow !== window { return }
            scheduleUpdate()
        }

        func scheduleUpdate() {
            guard !updatePending else { return }
            updatePending = true
            // AppKit can attach the observer while SwiftUI is laying out its body.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                updatePending = false
                let visible = window.map {
                    !NSApp.isHidden && $0.isVisible && $0.isOnActiveSpace && !$0.isMiniaturized
                        && $0.occlusionState.contains(.visible) && !isHiddenOrHasHiddenAncestor
                } ?? false
                guard lastValue != visible else { return }
                lastValue = visible
                action(visible)
            }
        }
    }
}
#endif
