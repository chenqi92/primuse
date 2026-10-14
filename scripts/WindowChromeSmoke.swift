import AppKit
import SwiftUI

private enum MainWindowOpener {
    static let mainWindowID = "window-chrome-smoke"
}

@main
struct WindowChromeSmoke: App {
    // PRODUCTION_MAIN_WINDOW_SCENE

    var body: some Scene {
        macAwareMainGroup { NavigationFixture() }
            .defaultSize(width: 600, height: 400)
    }
}

private struct NavigationFixture: View {
    @State private var revision = 0

    var body: some View {
        VStack(spacing: 0) {
            Text("Title bar").frame(height: 48)
            NavigationStack {
                Text("Page \(revision)")
                    .navigationBarBackButtonHidden(true)
            }
            .id(revision)
        }
        .background(WindowProbe())
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            ChromeChecks.shared.begin()
            for index in 1...12 {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) { revision = index }
                try? await Task.sleep(for: .milliseconds(100))
                ChromeChecks.shared.sample()
            }
            ChromeChecks.shared.finish()
        }
    }
}

private struct WindowProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> ProbeView { ProbeView() }
    func updateNSView(_ nsView: ProbeView, context: Context) {}
}

private final class ProbeView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        ChromeChecks.shared.attach(window)
    }
}

@MainActor
private final class ChromeChecks {
    static let shared = ChromeChecks()
    private weak var window: NSWindow?
    private var buttons: [NSButton] = []
    private var frames: [NSRect] = []
    private var failures = Set<String>()
    private var timer: Timer?
    private var samples = 0
    private let types: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]

    func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // Match the initial AppKit configuration; it must survive navigation
        // without another deferred repair hiding a transient visible title.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
    }

    func begin() {
        guard let window else { finish(); return }
        buttons = types.compactMap { window.standardWindowButton($0) }
        // Primuse centers native buttons on a 48-point custom title bar.
        // A title change must not send them back to AppKit's default baseline.
        for button in buttons {
            button.setFrameOrigin(NSPoint(x: button.frame.minX, y: button.frame.minY - 8))
        }
        frames = buttons.map { $0.convert($0.bounds, to: nil) }
        sample()
        let timer = Timer(timeInterval: 0.001, repeats: true) { _ in
            MainActor.assumeIsolated { ChromeChecks.shared.sample() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func sample() {
        guard let window else { failures.insert("Missing window"); return }
        samples += 1
        if window.titleVisibility != .hidden { failures.insert("Window title became visible") }
        if !window.titlebarAppearsTransparent { failures.insert("Title bar became opaque") }
        if buttons.count != types.count { failures.insert("Missing native window buttons"); return }
        for (index, type) in types.enumerated() {
            guard let button = window.standardWindowButton(type) else {
                failures.insert("Native button disappeared")
                continue
            }
            if button !== buttons[index] { failures.insert("Native button was replaced") }
            if button.convert(button.bounds, to: nil) != frames[index] {
                failures.insert("Native button moved")
            }
            var ancestor: NSView? = button
            while let view = ancestor, view !== window.contentView?.superview {
                if view.isHidden || view.alphaValue < 0.999 {
                    failures.insert("Native button or its container was hidden")
                }
                ancestor = view.superview
            }
        }
    }

    func finish() {
        timer?.invalidate()
        if samples == 0 { failures.insert("No window samples collected") }
        let result = failures.isEmpty
            ? "PASS: 12 navigation resets, hidden title, stable native buttons (\(samples) samples)"
            : "FAIL: \(failures.sorted().joined(separator: ", "))"
        FileHandle.standardError.write(Data((result + "\n").utf8))
        exit(failures.isEmpty ? 0 : 1)
    }
}
