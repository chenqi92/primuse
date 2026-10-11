// Native composition test: AlbumArtworkView is production code; library,
// source IO, and the inner image renderer are deterministic doubles.
import AppKit
import SwiftUI

typealias PlatformImage = NSImage
enum PrimuseKit {
    struct Album { let id = "album"; let title = "Album"; let artistName: String? = "Artist"; let year: Int? = 2026; let songCount = 1 }
    struct Song {
        let id: String
        var coverArtFileName: String? { id }
        let sourceID = "source"
        let filePath = "song.flac"
        let fileFormat = Format.flac
        let revision: String? = nil
    }
    enum Format: String { case flac }
}
enum ArtworkPresentationRole { case staticFirstFrame, animatedHero }
struct LibraryArtworkOwner { enum Kind { case album }; let kind: Kind; let id: String }
enum ArtworkSourceRequestIdentity {
    static func key(songID: String, artworkReference: String?, sourceID: String, filePath: String,
                    fileFormat: String, revision: String) -> String? { songID + revision }
}
extension Notification.Name {
    static let primuseArtworkDidCache = Self("ArtworkLayersSmoke.cache")
    static let primuseArtworkDidInvalidate = Self("ArtworkLayersSmoke.invalidate")
}
extension Image { init(platformImage: NSImage) { self.init(nsImage: platformImage) } }

@MainActor @Observable final class MusicLibrary {
    var artworkOverrideRevision = 0
    var selectedSong: PrimuseKit.Song?
    var uploadedContentID: String?
    var fallback: PrimuseKit.Song? = .init(id: "song")
    struct ArtworkPresentation { let uploadedContentID: String?; let selectedSong: PrimuseKit.Song? }
    func artworkPresentation(for owner: LibraryArtworkOwner) -> ArtworkPresentation {
        .init(uploadedContentID: uploadedContentID, selectedSong: selectedSong)
    }
    func scopedPreferredArtworkSong(forAlbumID: String) -> PrimuseKit.Song? { fallback }
}
@MainActor enum Loads {
    static var attempted: [String] = []
    static var available: Set<String> = []
    // Model the renderer's recent-miss cache across view recreation. A new
    // SwiftUI identity alone must not be mistaken for an invalidated lookup.
    static var recentFailures: Set<String> = []
}
@MainActor enum UploadedArtworkLoader {
    static func load(contentID: String?, apply: @MainActor (NSImage?) -> Void) async {
        guard let contentID else { apply(nil); return }
        Loads.attempted.append(contentID)
        guard Loads.available.contains(contentID) else { apply(nil); return }
        let context = CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8,
                                bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 1, green: 1, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        apply(NSImage(cgImage: context.makeImage()!, size: NSSize(width: 2, height: 2)))
    }
}
struct CachedArtworkView: View {
    let key: String
    let revisionToken: Int
    let showsPlaceholder: Bool
    var onResolutionChange: (Bool) -> Void
    @State private var resolved = false
    init(coverRef: String?, songID: String?, size: CGFloat, cornerRadius: CGFloat,
         sourceID: String? = nil, filePath: String? = nil, fileFormat: PrimuseKit.Format? = nil,
         placeholderIcon: String = "music.note", showsPlaceholder: Bool,
         presentationRole: ArtworkPresentationRole = .staticFirstFrame, animationRequiresPlayback: Bool = false,
         isPlaying: Bool = true, isAnimationVisible: Bool = true, revisionToken: Int = 0,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        key = songID ?? "placeholder"; self.revisionToken = revisionToken
        self.showsPlaceholder = showsPlaceholder
        self.onResolutionChange = onResolutionChange
    }
    init(albumID: String, albumTitle: String, artistName: String?, year: Int?, trackCount: Int,
         size: CGFloat, cornerRadius: CGFloat, showsPlaceholder: Bool,
         presentationRole: ArtworkPresentationRole, animationRequiresPlayback: Bool,
         isPlaying: Bool, isAnimationVisible: Bool,
         revisionToken: Int = 0,
         onResolutionChange: @escaping (Bool) -> Void = { _ in }) {
        key = albumID; self.revisionToken = revisionToken
        self.showsPlaceholder = showsPlaceholder
        self.onResolutionChange = onResolutionChange
    }
    var body: some View {
        let rgb: (Double, Double, Double) = !resolved ? (1, 0, 1)
            : key == "album" ? (0, 1, 0) : key == "override" ? (1, 0, 0) : (0, 0, 1)
        Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: resolved || showsPlaceholder ? 1 : 0)
        .task(id: "\(key)#rev\(revisionToken)") {
            guard key != "placeholder" else { return }
            Loads.attempted.append(key)
            let identity = "\(key)#rev\(revisionToken)"
            guard !Loads.recentFailures.contains(identity) else {
                onResolutionChange(false)
                return
            }
            try? await Task.sleep(for: .milliseconds(10))
            guard !Task.isCancelled else { return }
            resolved = Loads.available.contains(key)
            if !resolved { Loads.recentFailures.insert(identity) }
            onResolutionChange(resolved)
        }
    }
}

/* PRODUCTION_VIEW */

@main struct AlbumArtworkLayersSmoke {
    @MainActor static func main() {
        startArtworkSmokeBudget()
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { @MainActor in
            var failures = 0
            for (label, available, expected) in [
                ("cached album", Set(["album", "song"]), ["album"]),
                ("song fallback", Set(["song"]), ["album", "song"]),
                ("missing artwork", Set<String>(), ["album", "song"])
            ] {
                let library = MusicLibrary()
                Loads.attempted = []; Loads.available = available
                Loads.recentFailures = []
                let window = makeWindow(library)
                try? await Task.sleep(for: .milliseconds(300))
                let attempts = Loads.attempted
                if attempts != expected {
                    print("FAIL \(label): expected \(expected), got \(attempts)"); failures += 1
                } else { print("PASS \(label): \(attempts)") }
                if label == "missing artwork", !rendersPlaceholder(window) {
                    print("FAIL: both missing sources must retain the placeholder"); failures += 1
                }
                if label == "song fallback" {
                    Loads.available.insert("album"); Loads.attempted = []
                    NotificationCenter.default.post(name: .primuseArtworkDidInvalidate, object: "album")
                    try? await Task.sleep(for: .milliseconds(150))
                    if Loads.attempted != ["album"] || !rendersAlbumCover(window) {
                        print("FAIL: album invalidation must promote the new cached cover"); failures += 1
                    } else { print("PASS: invalidation promotes cached album cover") }
                }
                window.contentView = nil; window.close()
                try? await Task.sleep(for: .milliseconds(50))
            }
            for (label, notification) in [
                ("album cache notification", Notification(name: .primuseArtworkDidCache, object: "album")),
                ("global cache notification", Notification(name: .primuseArtworkDidCache, userInfo: ["all": true]))
            ] {
                let library = MusicLibrary()
                Loads.attempted = []; Loads.available = ["song"]; Loads.recentFailures = []
                let window = makeWindow(library)
                try? await Task.sleep(for: .milliseconds(300))
                guard Loads.recentFailures.contains("album#rev0") else {
                    fatalError("Fixture must retain the initial album miss before a cache notification")
                }
                Loads.attempted = []
                NotificationCenter.default.post(name: .primuseArtworkDidCache, object: "unrelated")
                try? await Task.sleep(for: .milliseconds(50))
                if !Loads.attempted.isEmpty {
                    print("FAIL: unrelated cache notifications must not reload album artwork"); failures += 1
                }
                Loads.available.insert("album")
                Loads.attempted = []
                NotificationCenter.default.post(notification)
                try? await Task.sleep(for: .milliseconds(300))
                if Loads.attempted != ["album"] || !rendersAlbumCover(window) {
                    print("FAIL \(label): a previous miss still prevents promotion: \(Loads.attempted)"); failures += 1
                } else { print("PASS \(label): previous miss no longer prevents promotion") }
                window.contentView = nil; window.close()
                try? await Task.sleep(for: .milliseconds(50))
            }
            for (label, role, override, expected) in [
                ("static album priority", ArtworkPresentationRole.staticFirstFrame, false, "green"),
                ("selected song priority", .staticFirstFrame, true, "red"),
                ("uploaded artwork priority", .staticFirstFrame, false, "yellow"),
                ("animated hero source priority", .animatedHero, false, "blue")
            ] {
                let library = MusicLibrary()
                Loads.recentFailures = []
                if override { library.selectedSong = .init(id: "override") }
                if expected == "yellow" { library.uploadedContentID = "upload" }
                Loads.available = ["album", "song", "override", "upload"]
                let window = makeWindow(library, role: role)
                try? await Task.sleep(for: .milliseconds(300))
                let view = window.contentView!
                view.layoutSubtreeIfNeeded()
                let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
                view.cacheDisplay(in: view.bounds, to: bitmap)
                guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB) else { fatalError("Missing rendered image") }
                let actual = color.redComponent > 0.8 && color.greenComponent > 0.8 ? "yellow"
                    : color.redComponent > 0.8 ? "red" : color.greenComponent > 0.8 ? "green" : color.blueComponent > 0.8 ? "blue" : "missing"
                if actual != expected {
                    print("FAIL \(label): expected \(expected), rendered \(actual)"); failures += 1
                } else { print("PASS \(label): rendered \(actual)") }
                window.contentView = nil; window.close()
                try? await Task.sleep(for: .milliseconds(50))
            }
            exit(failures == 0 ? 0 : 1)
        }
        NSApplication.shared.run()
    }
    @MainActor private static func rendersPlaceholder(_ window: NSWindow) -> Bool {
        guard let color = renderedColor(window) else { return false }
        // Magenta represents the renderer's requested placeholder in this fixture.
        return color.redComponent > color.greenComponent + 0.2
            && color.blueComponent > color.greenComponent + 0.2
    }
    @MainActor private static func rendersAlbumCover(_ window: NSWindow) -> Bool {
        guard let color = renderedColor(window) else { return false }
        // AppKit color management can change channel values. The album
        // fixture must remain green-dominant, distinct from the blue fallback.
        return color.greenComponent > color.redComponent + 0.2
            && color.greenComponent > color.blueComponent + 0.2
    }
    @MainActor private static func renderedColor(_ window: NSWindow) -> NSColor? {
        guard let view = window.contentView else { return nil }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.sRGB)
    }
    @MainActor private static func makeWindow(_ library: MusicLibrary, role: ArtworkPresentationRole = .staticFirstFrame) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 160, height: 160),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AlbumArtworkView(album: .init(), size: 150, presentationRole: role).environment(library))
        host.sizingOptions = []; host.frame = window.contentLayoutRect
        window.contentView = host; window.orderFront(nil)
        return window
    }
}
