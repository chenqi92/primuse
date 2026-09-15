import AppKit

@main
struct ScrollViewStyleSmoke {
    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let style = PMScrollViewStyle()
        style.install()
        style.install()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = makeScrollView()
        window.contentView = scroll

        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        precondition(scroll.scrollerStyle == .legacy, "Window notifications must defer AppKit mutations")
        try await Task.sleep(for: .milliseconds(100))
        checkStyle(scroll)

        let pending = makeScrollView()
        NotificationCenter.default.post(name: NSView.frameDidChangeNotification, object: pending)
        try await Task.sleep(for: .milliseconds(100))
        precondition(pending.scrollerStyle == .legacy, "An unmounted scroll view must wait for its window")
        scroll.addSubview(pending)
        NotificationCenter.default.post(name: NSWindow.didUpdateNotification, object: window)
        try await Task.sleep(for: .milliseconds(100))
        checkStyle(pending)

        pending.scrollerStyle = .legacy
        try await Task.sleep(for: .milliseconds(100))
        checkStyle(pending)
        precondition(!window.isVisible && !window.isKeyWindow)
        print("PASS: deferred window notifications, late mounting, and scroller style restoration")
    }

    @MainActor private static func makeScrollView() -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 150))
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy
        return scroll
    }

    @MainActor private static func checkStyle(_ scroll: NSScrollView) {
        MainActor.assertIsolated()
        precondition(scroll.scrollerStyle == .overlay)
        precondition(scroll.verticalScroller?.controlSize == .small)
        precondition(scroll.horizontalScroller?.controlSize == .small)
    }
}
