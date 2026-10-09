import AppKit
import SwiftUI

struct Album: Identifiable { let id: String }

@MainActor
final class AlbumBrowseDriver {
    var open: (() -> Void)?
    var close: (() -> Void)?
    var overviewEnabled = true
}

struct AlbumDetailView: View {
    let album: Album
    let onMacInlineBack: () -> Void

    var body: some View {
        VStack {
            Button("Back", action: onMacInlineBack)
            Text("Album detail")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.blue)
    }
}

struct AlbumOverviewFixture: View {
    let grid: Bool
    let driver: AlbumBrowseDriver
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Text("Albums").font(.title)
                if grid {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 24) {
                        ForEach(0..<180) { index in row(index).frame(height: 150) }
                    }
                } else {
                    LazyVStack(spacing: 1) {
                        ForEach(0..<180) { index in row(index).frame(height: 60) }
                    }
                }
            }
            .padding(24)
        }
        .onAppear { driver.overviewEnabled = isEnabled }
        .onChange(of: isEnabled) { _, enabled in driver.overviewEnabled = enabled }
    }

    private func row(_ index: Int) -> some View {
        Button { driver.open?() } label: {
            Text("Album \(index)")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(index.isMultiple(of: 2) ? Color.green : Color.orange)
        }
        .buttonStyle(.plain)
    }
}

/// Hosts the production navigation composition in real AppKit scroll views.
/// Content is deterministic; this does not launch the application or its services.
@main
struct AlbumBrowsePositionSmoke {
    @MainActor static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        var failures: [String] = []
        var roundTrips = 0
        for grid in [true, false] {
            for width: CGFloat in [520, 880] {
                let name = "\(grid ? "grid" : "list")-\(Int(width))"
                let driver = AlbumBrowseDriver()
                let host = NSHostingView(rootView: AlbumGridNavigationFixture(driver: driver, grid: grid)
                    .frame(width: width, height: 520))
                host.sizingOptions = []
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520),
                                      styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                host.frame = NSRect(x: 0, y: 0, width: width, height: 520)
                settle(host)
                guard abs(host.bounds.width - width) < 1, abs(host.bounds.height - 520) < 1 else {
                    throw Failure.wrongViewport
                }
                guard let initialScroll = scrollView(in: host), driver.open != nil, driver.close != nil else {
                    throw Failure.missingFixture
                }
                let bottom = max(0, initialScroll.documentView!.bounds.height - initialScroll.contentSize.height)
                for (position, target) in [("middle", CGFloat(1200)), ("bottom", bottom - 30), ("top", CGFloat(0))] {
                    for repetition in 1...2 {
                        let label = "\(name)-\(position)-\(repetition)"
                        guard let scroll = scrollView(in: host) else { throw Failure.missingFixture }
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: target))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        settle(host)
                        let before = scroll.contentView.bounds.origin.y
                        if abs(before - target) > 1 {
                            throw Failure.cannotSetPosition
                        }
                        try snapshot(host, to: output.appendingPathComponent(label + "-before.png"))
                        driver.open?()
                        settle(host)
                        if scrollView(in: host) != nil && driver.overviewEnabled {
                            failures.append("\(label): hidden overview still enables controls")
                        }
                        driver.close?()
                        settle(host)
                        guard let returnedScroll = scrollView(in: host) else { throw Failure.missingFixture }
                        let after = returnedScroll.contentView.bounds.origin.y
                        if abs(after - before) > 1 {
                            failures.append("\(label): returned to \(after), expected \(before)")
                        }
                        if !driver.overviewEnabled {
                            failures.append("\(label): overview controls remain disabled after returning")
                        }
                        try snapshot(host, to: output.appendingPathComponent(label + "-after.png"))
                        print("\(label): \(before) -> \(after)")
                        roundTrips += 1
                    }
                }
                window.close()
            }
        }
        failures.forEach { print("FAIL: \($0)") }
        print("\(failures.isEmpty ? "PASS" : "FAIL"): \(roundTrips) album browser round trips; \(failures.count) failures")
        if !failures.isEmpty { exit(1) }
    }

    @MainActor private static func settle(_ host: NSView) {
        let deadline = Date().addingTimeInterval(0.4)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        } while Date() < deadline
    }

    @MainActor private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { scrollView(in: $0) }.first
    }

    @MainActor private static func snapshot(_ view: NSView, to url: URL) throws {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw Failure.cannotRender
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: url)
    }

    private enum Failure: Error { case missingFixture, cannotSetPosition, cannotRender, wrongViewport }
}
