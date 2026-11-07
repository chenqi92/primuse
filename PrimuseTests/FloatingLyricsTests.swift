import AVFoundation
import PrimuseKit
import SwiftUI
import Vision
import XCTest
@testable import Primuse

@MainActor
final class FloatingLyricsTests: XCTestCase {
    private func player() throws -> AudioPlayerService {
        let suite = "FloatingLyricsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.lockScreenLyricsEnabled = false
        return AudioPlayerService(playbackSettings: settings, activateAudioSession: { _ in })
    }

    private func song(_ id: String) -> Song {
        Song(id: id, title: "Window Lights \(id)", duration: 120, fileFormat: .flac,
             filePath: "\(id).flac", sourceID: "floating-lyrics-fixture")
    }

    private func eventually(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(2)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    func testDisabledConsumerDoesNotLoadAndTurningOffClearsLyrics() async throws {
        let player = try player()
        player.currentSong = song("a")
        player.currentTime = 5
        var loads = 0
        let service = FloatingLyricsService { _ in
            loads += 1
            return [LyricLine(timestamp: 1, text: "晚风点亮窗边的灯")]
        }
        let consumer = UUID()
        service.setConsumer(consumer, active: false, player: player)
        await Task.yield()
        XCTAssertEqual(loads, 0)
        service.setConsumer(consumer, active: true, player: player)
        try await eventually { service.presentation.current == "晚风点亮窗边的灯" }
        XCTAssertEqual(loads, 1)
        service.setConsumer(consumer, active: false, player: player)
        XCTAssertNil(service.presentation.current)
        XCTAssertNil(service.songID)
    }

    func testOldSongLoadCannotOverwriteNewSongAndSeekWorksWhilePaused() async throws {
        let player = try player()
        var pending: [String: CheckedContinuation<[LyricLine], Never>] = [:]
        let service = FloatingLyricsService { song in
            await withCheckedContinuation { pending[song.id] = $0 }
        }
        let consumer = UUID()
        defer { service.setConsumer(consumer, active: false, player: player) }
        player.currentSong = song("a")
        player.currentTime = 5
        service.setConsumer(consumer, active: true, player: player)
        try await eventually { pending["a"] != nil }
        player.currentSong = song("b")
        try await eventually { pending["b"] != nil }
        pending.removeValue(forKey: "b")?.resume(returning: [
            LyricLine(timestamp: 1, text: "纸船载着星光回航"),
            LyricLine(timestamp: 10, text: "小巷收起最后的灯")
        ])
        try await eventually { service.presentation.current == "纸船载着星光回航" }
        pending.removeValue(forKey: "a")?.resume(returning: [LyricLine(timestamp: 1, text: "旧日的帆停在远方")])
        await Task.yield()
        XCTAssertEqual(service.presentation.current, "纸船载着星光回航")
        player.currentTime = 12
        try await eventually { service.presentation.current == "小巷收起最后的灯" }
        player.currentTime = 0
        try await eventually { service.presentation.current == nil }
        XCTAssertEqual(service.presentation.next, "纸船载着星光回航")
    }

    func testPictureInPictureKeepsLyricsAfterTheInlineConsumerLeaves() async throws {
        let player = try player()
        player.currentSong = song("a")
        player.currentTime = 5
        let updated = [LyricLine(timestamp: 1, text: "纸船驶过亮着灯的桥")]
        let service = FloatingLyricsService(cachedLyricsLoader: { _ in updated }) { _ in
            [LyricLine(timestamp: 1, text: "星光落在纸船上")]
        }
        let consumer = UUID()
        service.setConsumer(consumer, active: true, player: player)
        try await eventually { service.presentation.current != nil }
        service.setPictureInPictureDemand(true)
        service.setConsumer(consumer, active: false, player: player)
        XCTAssertEqual(service.presentation.current, "星光落在纸船上")
        MetadataAssetStore.postLyricsCached(songID: "a", lines: updated)
        try await eventually { service.presentation.current == updated[0].text }
        service.setPictureInPictureDemand(false)
        XCTAssertNil(service.presentation.current)
    }

    func testLateCachedLyricsRecoverAnEmptyMiniPlayerWithoutToggling() async throws {
        let player = try player()
        player.currentSong = song("late-cache")
        player.currentTime = 5
        let cached = [
            LyricLine(timestamp: 1, text: "雨停后窗边亮起一盏灯"),
            LyricLine(timestamp: 10, text: "小路把星光送到门前")
        ]
        var loads = 0
        var cacheReads: [String] = []
        let service = FloatingLyricsService(cachedLyricsLoader: { id in
            cacheReads.append(id)
            return cached
        }) { _ in
            loads += 1
            return []
        }
        let consumer = UUID()
        defer { service.setConsumer(consumer, active: false, player: player) }
        service.setConsumer(consumer, active: true, player: player)
        try await eventually { loads == 1 && !service.isLoading }
        XCTAssertNil(service.presentation.current)

        MetadataAssetStore.postLyricsCached(songID: "unrelated-song", lines: cached)
        MetadataAssetStore.postLyricsCached(songID: "late-cache", lines: cached)
        try await eventually { service.presentation.current == cached[0].text }
        XCTAssertEqual(cacheReads, ["late-cache"])
        XCTAssertEqual(loads, 1, "A cache notification must not start another source fetch")
        player.currentTime = 12
        try await eventually { service.presentation.current == cached[1].text }

        service.setConsumer(consumer, active: false, player: player)
        MetadataAssetStore.postLyricsCached(songID: "late-cache", lines: cached)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(cacheReads, ["late-cache"])
        XCTAssertNil(service.presentation.current)
    }

    func testLateSourceResultCannotOverwriteNewlyCachedLyrics() async throws {
        let player = try player()
        player.currentSong = song("pending-source")
        player.currentTime = 5
        let cached = [LyricLine(timestamp: 1, text: "新来的月光照亮小巷")]
        var pending: CheckedContinuation<[LyricLine], Never>?
        var sourceReturned = false
        let service = FloatingLyricsService(cachedLyricsLoader: { _ in cached }) { _ in
            let result = await withCheckedContinuation { pending = $0 }
            sourceReturned = true
            return result
        }
        let consumer = UUID()
        defer { service.setConsumer(consumer, active: false, player: player) }
        service.setConsumer(consumer, active: true, player: player)
        try await eventually { pending != nil }
        MetadataAssetStore.postLyricsCached(songID: "pending-source", lines: cached)
        try await eventually { service.presentation.current == cached[0].text }
        pending?.resume(returning: [])
        try await eventually { sourceReturned }
        XCTAssertEqual(service.presentation.current, cached[0].text)
        XCTAssertTrue(service.hasTimedLyrics)
    }

    func testOldCacheReadCannotOverwriteTheNextSong() async throws {
        let player = try player()
        player.currentSong = song("old-cache")
        player.currentTime = 5
        var pending: CheckedContinuation<[LyricLine]?, Never>?
        var cacheReturned = false
        let current = [LyricLine(timestamp: 1, text: "今天的风吹开一扇窗")]
        let service = FloatingLyricsService(cachedLyricsLoader: { _ in
            let result = await withCheckedContinuation { pending = $0 }
            cacheReturned = true
            return result
        }) { song in
            song.id == "next-song" ? current : []
        }
        let consumer = UUID()
        defer { service.setConsumer(consumer, active: false, player: player) }
        service.setConsumer(consumer, active: true, player: player)
        MetadataAssetStore.postLyricsCached(songID: "old-cache", lines: current)
        try await eventually { pending != nil }
        player.currentSong = song("next-song")
        try await eventually { service.presentation.current == current[0].text }
        pending?.resume(returning: [LyricLine(timestamp: 1, text: "昨天的灯留在远处")])
        try await eventually { cacheReturned }
        XCTAssertEqual(service.songID, "next-song")
        XCTAssertEqual(service.presentation.current, current[0].text)
    }

    func testPictureInPictureFrameContainsTextAndCanDisplayImmediately() throws {
        let frame = try XCTUnwrap(LyricsPictureInPicture.makeFrame(
            title: "Window Lights", current: "晚风点亮窗边的灯", next: "纸船载着星光回航"))
        let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame))
        XCTAssertEqual(CVPixelBufferGetWidth(pixels), 960)
        XCTAssertEqual(CVPixelBufferGetHeight(pixels), 540)
        let attachments = try XCTUnwrap(CMSampleBufferGetSampleAttachmentsArray(frame, createIfNecessary: false) as? [NSDictionary])
        XCTAssertEqual(attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] as? Bool, true)
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var textPixels = 0
        for y in 115..<370 {
            for x in 48..<912 where base[y * stride + x * 4 + 2] > 220 { textPixels += 1 }
        }
        XCTAssertGreaterThan(textPixels, 1000)
        let ciImage = CIImage(cvPixelBuffer: pixels)
        let image = try XCTUnwrap(CIContext().createCGImage(ciImage, from: ciImage.extent))
        let attachment = XCTAttachment(image: UIImage(cgImage: image))
        attachment.name = "Floating lyrics frame"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testVividAppearanceOnlyAppliesToMeshCoverBackgrounds() {
        for source in PlayerBackdropSource.allCases {
            for style in PlayerAmbientStyle.allCases {
                XCTAssertEqual(PlayerAppearancePreferences.usesVividMesh(enabled: true, source: source, style: style),
                               source == .coverAmbient && style == .mesh)
                XCTAssertFalse(PlayerAppearancePreferences.usesVividMesh(enabled: false, source: source, style: style))
            }
        }
    }

    func testPictureInPictureUsesArtworkColorsAndFitsLongLyrics() throws {
        for (name, color) in [("Blue cover", UIColor.systemBlue), ("Warm cover", UIColor.systemOrange),
                              ("Monochrome cover", UIColor.gray)] {
            let cover = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { renderer in
                color.setFill()
                renderer.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
            }
            let palette = ThemeService.extractLiquidPalette(from: cover)
            let frame = try XCTUnwrap(LyricsPictureInPicture.makeFrame(
                title: "Window Lights", current: "晚风把散落的星光轻轻放在窗边，等一艘纸船慢慢回航",
                next: "屋檐下的小灯还亮着", artist: "Paper Harbor", artwork: cover, palette: palette))
            let pixels = try XCTUnwrap(CMSampleBufferGetImageBuffer(frame))
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixels)).assumingMemoryBound(to: UInt8.self)
            let stride = CVPixelBufferGetBytesPerRow(pixels)
            let offset = 160 * stride + 480 * 4
            let red = Int(base[offset + 2]), blue = Int(base[offset])
            if name == "Blue cover" { XCTAssertGreaterThan(blue, red + 25) }
            if name == "Warm cover" { XCTAssertGreaterThan(red, blue + 25) }
            if name == "Monochrome cover" { XCTAssertLessThan(abs(red - blue), 3) }
            var secondLinePixels = 0
            for y in 290..<370 {
                for x in 56..<904 {
                    let pixel = y * stride + x * 4
                    if base[pixel] > 220, base[pixel + 1] > 220, base[pixel + 2] > 220 {
                        secondLinePixels += 1
                    }
                }
            }
            XCTAssertGreaterThan(secondLinePixels, 500, "Long lyrics must wrap below the first line")
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
            let ciImage = CIImage(cvPixelBuffer: pixels)
            let image = try XCTUnwrap(CIContext().createCGImage(ciImage, from: ciImage.extent))
            let attachment = XCTAttachment(image: UIImage(cgImage: image))
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testVividMeshRendersTheCoverColors() throws {
        let raw: [LiquidBackdropColor] = [
            .init(red: 0.94, green: 0.94, blue: 0.94),
            .init(red: 0.08, green: 0.22, blue: 0.57),
            .init(red: 0.12, green: 0.59, blue: 0.75),
            .init(red: 0.59, green: 0.43, blue: 0.75)
        ]
        let palette = MeshBackdropPalettePolicy.vividPalette(from: raw)
        let view = AdaptiveNowPlayingBackdrop(
            baseColor: Color(red: 0.035, green: 0.043, blue: 0.055),
            primaryAccent: .blue, secondaryAccent: .cyan, darkAccent: .blue,
            primaryOpacity: 0.9, secondaryOpacity: 0.7, hasArtworkPalette: true,
            isVisible: false, isSceneActive: true, isPlaying: false,
            paletteVibrancy: 0.8, paletteLuminance: 0.5,
            meshPalette: palette, usesVividPalette: true
        )
        .frame(width: 390, height: 600)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage)
        let cgImage = try XCTUnwrap(image.cgImage)
        let ciImage = CIImage(cgImage: cgImage)
        var bytes = [UInt8](repeating: 0, count: 390 * 600 * 4)
        CIContext().render(ciImage, toBitmap: &bytes, rowBytes: 390 * 4,
                           bounds: ciImage.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let bluePixels = stride(from: 0, to: bytes.count, by: 4).filter {
            Int(bytes[$0 + 2]) - Int(bytes[$0]) > 35
        }.count
        XCTAssertGreaterThan(bluePixels, 390 * 600 / 3)
        let attachment = XCTAttachment(image: image)
        attachment.name = "Vivid Mesh rendering"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
final class MiniPlayerLyricsRenderingTests: XCTestCase {
    func testLyricsRemainVisibleAcrossPlayerLayoutsAndTextSizes() async throws {
        try await checkRendering(lateLyrics: false)
    }

    func testMountedMinimalPlayerDisplaysLateLyricsAndSeekUpdates() async throws {
        try await checkRendering(lateLyrics: true)
    }

    func testMinimalInsetDisplaysNewlyCachedChineseLyricsWithoutRemounting() async throws {
        try await checkRendering(lateLyrics: true, cachedLyrics: true)
    }

    private func checkRendering(lateLyrics: Bool, cachedLyrics: Bool = false) async throws {
        let suite = "MiniPlayerLyricsRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: PlayerAppearancePreferences.miniPlayerLyricsKey)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let library = MusicLibrary(storageDirectory: directory, searchIndexDefaults: defaults, startsPreparing: true)
        let settings = PlaybackSettingsStore(defaults: defaults)
        settings.lockScreenLyricsEnabled = false
        let player = AudioPlayerService(playbackSettings: settings, activateAudioSession: { _ in })
        let song = Song(id: suite, title: "天狐 (Live)", duration: 120, fileFormat: .flac,
                        filePath: "", sourceID: "mini-lyrics-rendering-fixture")
        if cachedLyrics {
            addTeardownBlock { _ = await MetadataAssetStore.shared.invalidateLyricsCache(forSongID: song.id) }
        }
        player.currentSong = song
        player.currentTime = 5
        let service = FloatingLyricsService.shared
        let consumer = UUID()
        service.setConsumer(consumer, active: true, player: player)
        defer { service.setConsumer(consumer, active: false, player: player) }
        let lines = [LyricLine(timestamp: 1, text: cachedLyrics ? "晚风点亮窗边灯" : "Moonlight"),
                     LyricLine(timestamp: 10, text: cachedLyrics ? "纸船载着星光回航" : "Starlight")]
        func publishLyrics() async throws {
            if cachedLyrics {
                XCTAssertNil(service.presentation.current)
                let saved = await MetadataAssetStore.shared.cacheLyrics(lines, forSongID: song.id)
                XCTAssertTrue(saved)
            } else {
                NotificationCenter.default.post(name: .primuseLyricsDidChange, object: song.id,
                                                userInfo: ["lyrics": lines])
            }
            let deadline = Date().addingTimeInterval(1)
            while service.presentation.current != lines[0].text, Date() < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(service.presentation.current, lines[0].text)
        }
        if !lateLyrics { try await publishLyrics() }

        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: AnyView(EmptyView()))
        host.safeAreaRegions = []
        window.rootViewController = host
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        let cases: [(String, CGFloat, DynamicTypeSize)] = lateLyrics
            ? [(cachedLyrics ? "minimal-inset-cache" : "minimal-settings", 390, .large)]
            : [("standard", 390, .large), ("minimal", 390, .large),
               ("minimal-small", 320, .large), ("minimal-large-text", 390, .accessibility1),
               ("minimal-settings", 390, .large), ("minimal-inset", 390, .large)]
        for (name, width, textSize) in cases {
            let dock = MinimalNowPlayingAccessory(onTap: {}, onShowQueue: {})
            let content: AnyView
            switch name {
            case "standard":
                content = AnyView(VStack { Spacer(); LegacyNowPlayingAccessory(onTap: {}) })
            case "minimal-settings":
                content = AnyView(Form { Text("Settings") }.minimalSafeAreaBar(edge: .bottom) { dock })
            case "minimal-inset", "minimal-inset-cache":
                content = AnyView(Form { Text("Settings") }.safeAreaInset(edge: .bottom) { dock.background(.bar) })
            default:
                content = AnyView(VStack { Spacer(); dock })
            }
            window.frame = CGRect(x: 0, y: 0, width: width, height: 300)
            host.rootView = AnyView(content
                .frame(width: width, height: 300)
                .background(Color.white)
                .environment(player)
                .environment(library)
                .environment(AppServices.shared.sourceManager)
                .environment(\.colorScheme, .light)
                .dynamicTypeSize(textSize)
                .defaultAppStorage(defaults))
            try await Task.sleep(for: .milliseconds(250))
            if cachedLyrics { try assertVisible(lines[0].text, in: host, name: name + "-empty", expected: false) }
            if lateLyrics { try await publishLyrics() }
            try assertVisible(lines[0].text, in: host, name: name)
            if lateLyrics {
                player.currentTime = 12
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertEqual(service.presentation.current, lines[1].text)
                try assertVisible(lines[1].text, in: host, name: name + "-seek")
                defaults.set(false, forKey: PlayerAppearancePreferences.miniPlayerLyricsKey)
                try await Task.sleep(for: .milliseconds(250))
                try assertVisible(lines[1].text, in: host, name: name + "-disabled", expected: false)
            }
        }
    }

    private func assertVisible(_ lyric: String, in host: UIViewController, name: String,
                               expected: Bool = true) throws {
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = lyric.canBeConverted(to: .ascii) ? ["en-US"] : ["zh-Hans"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        XCTAssertEqual(text.contains(lyric), expected, "\(name): visible text = \(text)")
    }
}
