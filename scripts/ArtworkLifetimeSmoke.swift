import AppKit
import SwiftUI

typealias PlatformImage = NSImage

@MainActor private final class ImageProbe {
    static let shared = ImageProbe()
    let cache = NSCache<NSString, NSImage>()
    var images: [Int: WeakImage] = [:]
    var visible = Set<Int>()
    var loaded = Set<Int>()

    func image(for id: Int) -> NSImage {
        let key = "\(id)" as NSString
        if let image = cache.object(forKey: key) { return image }
        // A real, unique decoded bitmap, with bounded total allocation (< 64 MiB).
        let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                                bytesPerRow: 2048, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(NSColor(hue: CGFloat(id) / 60, saturation: 0.7,
                                     brightness: 0.8, alpha: 1).cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 512, height: 512))
        let image = NSImage(cgImage: context.makeImage()!, size: NSSize(width: 512, height: 512))
        cache.setObject(image, forKey: key, cost: 512 * 512 * 4)
        images[id] = WeakImage(image)
        loaded.insert(id)
        return image
    }
}

private final class WeakImage {
    weak var image: NSImage?
    init(_ image: NSImage) { self.image = image }
}

private struct ArtworkProbe: View {
    let id: Int
    /* PRODUCTION_IMAGE_STATE */
    @State private var loadedIdentity: String?
    @State private var displayedArtworkIdentity: String?
    @State private var holdsPreviousArtwork = false
    @State private var placeholderRevealed = false
    @State private var isArtworkVisible = true
    @State private var resolvedAppleMusicArtwork: Int?
    @State private var resolvedAppleMusicArtworkID: String?
    private let crossfadesArtwork = false
    private var artworkContentIdentity: String { "\(id)" }
    private var cacheKey: String { "\(id)" }
    private static var memoryCache: NSCache<NSString, NSImage> { ImageProbe.shared.cache }
    private func cachedLowerResolutionImage() -> NSImage? { nil }
    private func clearAnimatedArtworkCache() {}
    /* PRODUCTION_DISPLAYED_IMAGE */
    /* PRODUCTION_RELEASE */

    var body: some View {
        Group {
            if let displayedImage {
                Image(nsImage: displayedImage).resizable()
            } else {
                Color.gray
            }
        }
        .frame(width: 100, height: 100)
        .onAppear {
            isArtworkVisible = true
            ImageProbe.shared.visible.insert(id)
        }
        .task(id: isArtworkVisible) {
            guard isArtworkVisible else { return }
            image = ImageProbe.shared.image(for: id)
            displayedArtworkIdentity = artworkContentIdentity
            loadedIdentity = artworkContentIdentity
        }
        /* PRODUCTION_DISAPPEAR */
        /* PRODUCTION_VISIBILITY */
        .onDisappear { ImageProbe.shared.visible.remove(id) }
    }
}

@main struct ArtworkLifetimeSmoke {
    @MainActor static func main() {
        startArtworkSmokeBudget()
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                try await run()
                exit(0)
            } catch {
                print("FAIL: \(error)")
                exit(1)
            }
        }
        // Use AppKit's event loop, including its autorelease-pool drains. An
        // async main alone can keep autoreleased NSImages alive artificially.
        NSApplication.shared.run()
    }

    @MainActor private static func run() async throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 260),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(100)), count: 4)) {
                ForEach(0..<60) { ArtworkProbe(id: $0) }
            }
        })
        host.sizingOptions = []
        host.frame = window.contentLayoutRect
        window.contentView = host
        window.orderFront(nil)
        try await settle(host)
        guard let scroll = findScroll(host) else { fatalError("Missing native scroll view") }
        for page in 0..<6 {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: CGFloat(page) * 270))
            scroll.reflectScrolledClipView(scroll.contentView)
            try await settle(host)
        }
        ImageProbe.shared.cache.removeAllObjects()
        try await settle(host)
        let probe = ImageProbe.shared
        let offscreen = probe.loaded.subtracting(probe.visible)
        let retained = offscreen.filter { probe.images[$0]?.image != nil }
        print("Loaded: \(probe.loaded.count); visible: \(probe.visible.count); offscreen: \(offscreen.count); retained offscreen after purge: \(retained.count)")
        guard offscreen.count >= 24 else { fatalError("Fixture did not scroll enough to test retention") }
        guard retained.isEmpty else {
            print("FAIL: offscreen lazy-grid state still owns decoded images after cache purge")
            exit(1)
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        try await settle(host)
        guard probe.visible.contains(0), probe.images[0]?.image != nil else {
            fatalError("Returning to a released card must reload its image")
        }
        print("PASS: offscreen images released; returning to the first page reloads artwork")

        // The same artwork view is also used outside scrolling containers,
        // including player surfaces. Scroll visibility must not blank those.
        let plainHost = NSHostingView(rootView: ArtworkProbe(id: 60))
        plainHost.sizingOptions = []
        plainHost.frame = window.contentLayoutRect
        window.contentView = plainHost
        try await settle(plainHost)
        ImageProbe.shared.cache.removeAllObjects()
        try await settle(plainHost)
        let bitmap = plainHost.bitmapImageRepForCachingDisplay(in: plainHost.bounds)!
        plainHost.cacheDisplay(in: plainHost.bounds, to: bitmap)
        let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
        guard probe.images[60]?.image != nil, let center,
              center.redComponent > center.greenComponent + 0.2 else {
            fatalError("Artwork outside a scroll view must remain visible after cache eviction")
        }
        print("PASS: artwork outside a scroll view remains visible after cache eviction")
    }

    @MainActor private static func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
    }

    @MainActor private static func findScroll(_ view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap { findScroll($0) }.first
    }
}
