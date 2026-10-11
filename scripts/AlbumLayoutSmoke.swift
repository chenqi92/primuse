import AppKit
import SwiftUI

struct Album: Identifiable {
    let id: Int
    let title = "A deliberately long album title with 日本語 and 中文 for layout coverage"
    let artistName: String? = "A long artist name"
}
/* PRODUCTION_SPACING */
enum PMRadius { static let m: CGFloat = 12 }
enum PMColor { static let bg = Color.black; static let text = Color.white; static let textMuted = Color.gray; static let textFaint = Color.gray }
extension View {
    func pmAppearFade() -> some View { self }
    func pmHoverLift() -> some View { self }
    func pmRowBackground(cornerRadius: CGFloat) -> some View { self }
}
struct LibraryInsightBatchStatusCard: View {
    enum Kind { case album }
    let kind: Kind; let outerPadding: EdgeInsets
    var body: some View { EmptyView() }
}
struct MeasuredBox: NSViewRepresentable {
    let id: String
    func makeNSView(context: Context) -> NSView {
        let view = NSView(); view.identifier = NSUserInterfaceItemIdentifier(id)
        view.wantsLayer = true; view.layer?.backgroundColor = NSColor.systemTeal.cgColor
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}
struct AlbumArtworkView: View {
    let album: Album; let size: CGFloat; let cornerRadius: CGFloat
    var body: some View { MeasuredBox(id: "cover-\(album.id)").frame(width: size, height: size) }
}

/* PRODUCTION_METRICS */

struct AlbumLayoutFixture: View {
    enum Mode { case grid, list }
    let albumViewMode: Mode
    let filteredAlbums = (0..<120).map { Album(id: $0) }
    var sortedAlbums: [Album]? { filteredAlbums }
    let albumFilter = ""
    var body: some View { macAlbumOverview }
    func albumsHeader(displayedCount: Int) -> some View { MeasuredBox(id: "header").frame(height: 44) }
    func openAlbum(_ album: Album) {}
    func albumMenu(_ album: Album) -> some View { EmptyView() }
    func albumMetaLine(_ album: Album) -> String { "2026 · 12 songs" }
    /* PRODUCTION_OVERVIEW */
    /* PRODUCTION_TILE */
    /* PRODUCTION_ROW */
}

@main struct AlbumLayoutSmoke {
    @MainActor static func main() {
        startArtworkSmokeBudget()
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var failures = 0
            for scrollerStyle in [NSScroller.Style.overlay, .legacy] {
                for mode in [AlbumLayoutFixture.Mode.grid, .list] {
                    for width: CGFloat in [360, 520, 880, 1360] {
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 520),
                                              styleMask: .borderless, backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        let host = NSHostingView(rootView: AlbumLayoutFixture(albumViewMode: mode))
                        host.sizingOptions = []; host.frame = window.contentLayoutRect
                        window.contentView = host; window.orderFront(nil)
                        try? await Task.sleep(for: .milliseconds(200))
                        host.layoutSubtreeIfNeeded()
                        let views = descendants(host)
                        guard let scroll = views.compactMap({ $0 as? NSScrollView }).first,
                              let header = views.first(where: { $0.identifier?.rawValue == "header" }) else { fatalError("Missing fixture") }
                        scroll.scrollerStyle = scrollerStyle
                        try? await Task.sleep(for: .milliseconds(100))
                        host.layoutSubtreeIfNeeded()
                        let headerBefore = header.convert(header.bounds, to: host)
                        let covers = descendants(host).filter { $0.identifier?.rawValue.hasPrefix("cover-") == true }
                        if covers.isEmpty { print("FAIL: fixture mounted no covers"); failures += 1 }
                        if let first = covers.first, covers.contains(where: { abs($0.bounds.width - first.bounds.width) > 1 }) {
                            print("FAIL: cards in one mode must share a cover size"); failures += 1
                        }
                        for cover in covers {
                            let rect = cover.convert(cover.bounds, to: scroll.contentView)
                            if rect.width <= 0 || abs(rect.width - rect.height) > 1
                                || rect.minX < scroll.contentView.bounds.minX - 1
                                || rect.maxX > scroll.contentView.bounds.maxX + 1 {
                                print("FAIL: \(mode) \(width) invalid cover frame \(rect)"); failures += 1
                            }
                        }
                        scroll.contentView.scroll(to: NSPoint(x: 0, y: 800))
                        scroll.reflectScrolledClipView(scroll.contentView)
                        try? await Task.sleep(for: .milliseconds(200))
                        if abs(scroll.contentView.bounds.origin.y - 800) > 1 {
                            print("FAIL: \(mode) \(width) content did not reach the requested scroll position"); failures += 1
                        }
                        let headerAfter = header.convert(header.bounds, to: host)
                        if abs(headerAfter.minY - headerBefore.minY) > 1 {
                            print("FAIL: \(mode) \(width) filter header scrolls away"); failures += 1
                        }
                        if !scroll.hasVerticalScroller { print("FAIL: \(mode) \(width) scroll indicator disabled"); failures += 1 }
                        print("Checked \(scrollerStyle) \(mode) at \(Int(width))pt: \(covers.count) mounted covers; header delta \(headerAfter.minY - headerBefore.minY)")
                        window.contentView = nil; window.close()
                    }
                }
            }
            print("\(failures == 0 ? "PASS" : "FAIL"): responsive covers and persistent controls; \(failures) failures")
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
    @MainActor private static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants($0) }
    }
}
