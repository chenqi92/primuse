#if os(tvOS)
import UIKit
import SwiftUI
import PrimuseKit
import XCTest
@testable import PrimuseTV

final class TVColorBackgroundIsolationTests: XCTestCase {
    func testArtworkPaletteCacheRetainsLegacyColorsAndMeshSwatches() throws {
        let legacy = Data(#"{"primary":{"red":0.2,"green":0.3,"blue":0.4},"secondary":{"red":0.1,"green":0.2,"blue":0.3}}"#.utf8)
        var palette = try JSONDecoder().decode(TVArtworkPalette.self, from: legacy)
        XCTAssertNil(palette.ambient)
        XCTAssertEqual(palette.primary.red, 0.2)
        palette.ambient = [palette.primary, palette.secondary]
        let decoded = try JSONDecoder().decode(TVArtworkPalette.self, from: JSONEncoder().encode(palette))
        XCTAssertEqual(decoded, palette)
    }

    func testDynamicColorResolvesOutsideMainActor() async {
        let result = await Task.detached {
            let dynamicColor = UIColor(TVColor.bg)
            let light = dynamicColor.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: .light)
            )
            let dark = dynamicColor.resolvedColor(
                with: UITraitCollection(userInterfaceStyle: .dark)
            )

            var lightRed: CGFloat = 0
            var lightGreen: CGFloat = 0
            var lightBlue: CGFloat = 0
            var lightAlpha: CGFloat = 0
            var darkRed: CGFloat = 0
            var darkGreen: CGFloat = 0
            var darkBlue: CGFloat = 0
            var darkAlpha: CGFloat = 0

            let resolvedLight = light.getRed(
                &lightRed,
                green: &lightGreen,
                blue: &lightBlue,
                alpha: &lightAlpha
            )
            let resolvedDark = dark.getRed(
                &darkRed,
                green: &darkGreen,
                blue: &darkBlue,
                alpha: &darkAlpha
            )

            return (
                resolvedLight: resolvedLight,
                resolvedDark: resolvedDark,
                lightRed: lightRed,
                lightGreen: lightGreen,
                lightBlue: lightBlue,
                lightAlpha: lightAlpha,
                darkRed: darkRed,
                darkGreen: darkGreen,
                darkBlue: darkBlue,
                darkAlpha: darkAlpha
            )
        }.value

        XCTAssertTrue(result.resolvedLight)
        XCTAssertTrue(result.resolvedDark)
        XCTAssertEqual(result.lightRed, CGFloat(0xF2) / 255, accuracy: 0.001)
        XCTAssertEqual(result.lightGreen, CGFloat(0xEF) / 255, accuracy: 0.001)
        XCTAssertEqual(result.lightBlue, CGFloat(0xEB) / 255, accuracy: 0.001)
        XCTAssertEqual(result.lightAlpha, 1, accuracy: 0.001)
        XCTAssertEqual(result.darkRed, 0, accuracy: 0.001)
        XCTAssertEqual(result.darkGreen, 0, accuracy: 0.001)
        XCTAssertEqual(result.darkBlue, 0, accuracy: 0.001)
        XCTAssertEqual(result.darkAlpha, 1, accuracy: 0.001)
    }
}

@MainActor
final class TVLiquidBackdropTests: XCTestCase {
    func testLiquidCanBeSelectedAndRestoredOnTV() throws {
        XCTAssertTrue(TVPlayerBackdropSettingsView.sourceRows.flatMap { $0 }.contains(.liquid))
        let suiteName = "TVLiquidBackdropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        settings.update { $0.source = .liquid }
        let restored = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        XCTAssertEqual(restored.effectiveSource, .liquid)
    }

    func testRenderedLiquidMovesAndStopsForPauseAndBackground() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let suiteName = "TVLiquidBackdropTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.set(true, forKey: AppThemePreferences.coverDrivenAmbientKey)
        defaults.set(0.7, forKey: AppThemePreferences.ambientStrengthKey)
        let previous = scene.windows.first { $0.isKeyWindow }
        let probe = LiquidProbe()
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: LiquidHarness(probe: probe).defaultAppStorage(defaults))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            defaults.removePersistentDomain(forName: suiteName)
        }
        for _ in 0..<30 where scene.activationState != .foregroundActive {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(scene.activationState, .foregroundActive)
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let first = pixels(window)
        try await Task.sleep(for: .milliseconds(600))
        let second = pixels(window)
        if first == second {
            let attachment = XCTAttachment(data: first, uniformTypeIdentifier: "public.png")
            attachment.name = "Initial TV liquid backdrop"
            add(attachment)
        }
        XCTAssertNotEqual(first, second, "The TV liquid backdrop must animate its actual rendered pixels")

        for mode in 0..<2 {
            probe.playing = mode != 0
            probe.active = mode != 1
            try await Task.sleep(for: .milliseconds(150))
            let stopped = pixels(window)
            try await Task.sleep(for: .milliseconds(250))
            XCTAssertEqual(stopped, pixels(window), "Motion must stop for pause and background")
        }
        probe.playing = true
        probe.active = true
        try await Task.sleep(for: .milliseconds(150))
        let resumed = pixels(window)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNotEqual(resumed, pixels(window))
    }

    private func pixels(_ window: UIWindow) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 90), format: format).image { context in
            context.cgContext.scaleBy(x: 160 / window.bounds.width, y: 90 / window.bounds.height)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        return image.pngData() ?? Data()
    }

    @Observable final class LiquidProbe {
        var playing = true
        var active = true
    }

    private struct LiquidHarness: View {
        let probe: LiquidProbe
        var body: some View {
            TVAmbientBackdrop(
                strength: 1,
                liquidPalette: [
                    .init(red: 0.9, green: 0.15, blue: 0.1),
                    .init(red: 0.1, green: 0.25, blue: 0.9),
                    .init(red: 0.2, green: 0.8, blue: 0.3)
                ],
                isPlaying: probe.playing
            )
            .environment(\.scenePhase, probe.active ? .active : .background)
            .environment(\.colorScheme, .dark)
        }
    }
}

@MainActor
final class TVImmersiveGalleryAnimationTests: XCTestCase {
    func testPlayerGalleryAnimatesAcrossFullScreenEntryCoverAndReentry() async throws {
        try XCTSkipIf(UIAccessibility.isReduceMotionEnabled, "This regression checks unrestricted background motion")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let defaultsName = "TVImmersiveGalleryAnimationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.set(FullscreenPlayerEffect.coverGallery.rawValue, forKey: FullscreenPlayerEffect.storageKey)
        let library = MusicLibrary(storageDirectory: directory)
        let sources = SourcesStore(storageDirectoryURL: directory)
        try sources.addDurably(MusicSource(id: "gallery-source", name: "Gallery", type: .local))
        let songs = (0..<4).map { index in
            Song(id: "gallery-\(index)", title: "Gallery \(index)", albumTitle: "Album \(index)",
                 artistName: "Gallery Artist", duration: 180, fileFormat: .mp3,
                 filePath: "/gallery-\(index).mp3", sourceID: "gallery-source",
                 coverArtFileName: "gallery-cover-\(index).jpg")
        }
        library.addSongs(songs)
        await library.waitForPendingIndex()
        let store = TVStore(sourcesStore: sources, library: library,
                            defaults: defaults, sessionStore: PlaybackSessionStore(url: directory.appendingPathComponent("session.json")))
        store.reload()
        XCTAssertEqual(store.songs.count, songs.count)
        store.nowPlaying.songID = songs[0].id
        store.nowPlaying.title = songs[0].title
        store.hasNowPlaying = true
        store.engine.beginExternalPlayback(duration: 180, transport: .init(pause: {}, resume: {}, seek: { _ in }, stop: {}))
        store.engine.updateExternalPlayback(currentTime: 0, duration: 180, isPlaying: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let presentation = GalleryPresentationProbe()
        let player = TVImmersivePlayerView().environment(store)
            .defaultAppStorage(defaults)
            .environment(MusicIntelligenceService()).environment(TVThemeState.shared).environment(TVAppearanceState())
        let host = UIHostingController(rootView: GalleryPresentationHarness(probe: presentation, player: player))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
            store.engine.stop()
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: directory)
        }
        for _ in 0..<30 where scene.activationState != .foregroundActive {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(scene.activationState, .foregroundActive)
        try await Task.sleep(for: .milliseconds(200))
        presentation.isPresented = true
        for phase in 0..<3 {
            try await Task.sleep(for: .milliseconds(1200))
            let playerHost = try XCTUnwrap(host.presentedViewController)
            XCTAssertTrue(store.isPlaying)
            let first = galleryPixels(window)
            try await Task.sleep(for: .milliseconds(800))
            try assertMotion(between: first, and: galleryPixels(window), expected: true,
                             "Player gallery on entry, after a cover, and on reentry, phase \(phase)")
            if phase == 0 {
                let cover = UIHostingController(rootView: Color.black)
                cover.modalPresentationStyle = .fullScreen
                await withCheckedContinuation { continuation in
                    playerHost.present(cover, animated: false) { continuation.resume() }
                }
                try await Task.sleep(for: .milliseconds(300))
                await withCheckedContinuation { continuation in
                    playerHost.dismiss(animated: false) { continuation.resume() }
                }
            } else if phase == 1 {
                presentation.isPresented = false
                try await Task.sleep(for: .milliseconds(800))
                XCTAssertNil(host.presentedViewController)
                presentation.isPresented = true
            }
        }
    }

    @Observable final class GalleryPresentationProbe {
        var isPresented = false
    }

    private struct GalleryPresentationHarness<Player: View>: View {
        let probe: GalleryPresentationProbe
        let player: Player

        var body: some View {
            Color.black
                .fullScreenCover(isPresented: Binding(
                    get: { probe.isPresented },
                    set: { probe.isPresented = $0 }
                )) { player }
        }
    }

    private func galleryPixels(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 240, height: 135), format: format).image { context in
            context.cgContext.scaleBy(x: 960 / window.bounds.width, y: 540 / window.bounds.height)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func testGalleryStartsAndResumesWithoutPlaybackTicksOrSpectrum() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let probe = GalleryProbe()
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: GalleryHarness(probe: probe))
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }
        for _ in 0..<30 where scene.activationState != .foregroundActive {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(scene.activationState, .foregroundActive)
        for phase in 0..<3 {
            probe.active = true
            probe.playing = true
            probe.reduceMotion = false
            try await Task.sleep(for: .milliseconds(300))
            let moving = pixels(window)
            try await Task.sleep(for: .milliseconds(700))
            try assertMotion(between: moving, and: pixels(window), expected: true,
                             "Gallery without spectrum or playback-time updates, phase \(phase)")

            switch phase {
            case 0: probe.active = false
            case 1: probe.playing = false
            default: probe.reduceMotion = true
            }
            try await Task.sleep(for: .milliseconds(300))
            let stopped = pixels(window)
            try await Task.sleep(for: .milliseconds(300))
            try assertMotion(between: stopped, and: pixels(window), expected: false,
                             "Hidden, paused, or reduced-motion gallery, phase \(phase)")
        }
    }

    private func pixels(_ window: UIWindow) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 320, height: 180), format: format).image { context in
            context.cgContext.scaleBy(x: 320 / window.bounds.width, y: 180 / window.bounds.height)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    private func assertMotion(between first: UIImage, and second: UIImage, expected: Bool,
                              _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        func rgba(_ image: UIImage) throws -> [UInt8] {
            let image = try XCTUnwrap(image.cgImage)
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(
                    data: buffer.baseAddress, width: image.width, height: image.height,
                    bitsPerComponent: 8, bytesPerRow: image.width * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                ))
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return bytes
        }
        let lhs = try rgba(first), rhs = try rgba(second)
        XCTAssertEqual(lhs.count, rhs.count, file: file, line: line)
        guard lhs.count == rhs.count, !lhs.isEmpty else { return }
        var difference = 0
        for index in lhs.indices where index % 4 != 3 {
            difference += abs(Int(lhs[index]) - Int(rhs[index]))
        }
        let meanDifference = Double(difference) / Double(lhs.count / 4 * 3)
        // Ignore rasterization noise while detecting the gallery's slow tile movement.
        let moves = meanDifference > 0.05
        print("\(message): mean RGB difference=\(meanDifference)")
        if moves != expected {
            for (name, image) in [("before", first), ("after", second)] {
                let attachment = XCTAttachment(image: image)
                attachment.name = "\(message) \(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
        XCTAssertEqual(moves, expected, "\(message); mean RGB difference=\(meanDifference)", file: file, line: line)
    }

    @Observable final class GalleryProbe {
        var active = false
        var playing = false
        var reduceMotion = false
    }

    private struct GalleryHarness: View {
        let probe: GalleryProbe
        var body: some View {
            GeometryReader { geometry in
                ImmersiveStageView(
                    style: .coverGallery,
                    platform: .tvOS,
                    metrics: ImmersiveStageMetrics(size: geometry.size, prefersWide: true),
                    track: ImmersiveStageTrack(title: "Gallery", artist: "", album: "", format: "", isPlaying: probe.playing, progress: 0),
                    galleryArtworkCount: 4,
                    galleryArtwork: { index, _ in AnyView([Color.red, .green, .blue, .yellow][index]) },
                    isRenderingActive: probe.active,
                    reduceMotion: probe.reduceMotion,
                    showsPlaybackProgress: false
                ) { _ in Color.gray }
            }
            .ignoresSafeArea()
        }
    }
}

@MainActor
final class TVAppearanceApplicationTests: XCTestCase {
    func testLightAppearanceAppliesImmediatelyAndRemainsAfterDelay() async throws {
        let (state, defaults, suiteName) = makeState()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let window = UIWindow(frame: .zero)

        state.select(.light)
        TVWindowAppearanceApplicator.apply(state.preference, to: [window])

        XCTAssertEqual(state.preference, .light)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "light")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
        try await Task.sleep(for: .seconds(12))
        XCTAssertEqual(state.preference, .light)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "light")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
    }

    func testDarkAppearanceAppliesImmediatelyAndRemainsAfterDelay() async throws {
        let (state, defaults, suiteName) = makeState()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let window = UIWindow(frame: .zero)

        state.select(.dark)
        TVWindowAppearanceApplicator.apply(state.preference, to: [window])

        XCTAssertEqual(state.preference, .dark)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "dark")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
        try await Task.sleep(for: .seconds(12))
        XCTAssertEqual(state.preference, .dark)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "dark")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)
    }

    func testConsecutiveAppearanceChangesUseLatestSelection() {
        let (state, defaults, suiteName) = makeState()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let window = UIWindow(frame: .zero)

        state.select(.light)
        TVWindowAppearanceApplicator.apply(state.preference, to: [window])
        XCTAssertEqual(state.preference, .light)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "light")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)

        state.select(.dark)
        TVWindowAppearanceApplicator.apply(state.preference, to: [window])
        XCTAssertEqual(state.preference, .dark)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "dark")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .dark)

        state.select(.light)
        TVWindowAppearanceApplicator.apply(state.preference, to: [window])
        XCTAssertEqual(state.preference, .light)
        XCTAssertEqual(defaults.string(forKey: TVAppearancePreference.storageKey), "light")
        XCTAssertEqual(window.overrideUserInterfaceStyle, .light)
    }

    private func makeState() -> (TVAppearanceState, UserDefaults, String) {
        let suiteName = "TVAppearanceApplicationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (TVAppearanceState(defaults: defaults), defaults, suiteName)
    }
}

@MainActor
final class PlayerLyricsColorRenderingTests: XCTestCase {
    private struct Sample: View {
        var colors = PlayerLyricsColors()
        var active = true
        var direction: LayoutDirection = .leftToRight
        var body: some View {
            Rectangle().fill(colors.style(defaultColor: .white, isActive: active, layoutDirection: direction))
        }
    }

    func testCustomColorUsesSharedStorageAndLeavesInactiveLyricsUnchanged() throws {
        try withDefaults { defaults in
            defaults.set("custom", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set(" #ff0000 ", forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            let active = try render(Sample(), defaults: defaults)
            XCTAssertGreaterThan(active[0], 240)
            XCTAssertLessThan(active[1], 10)
            let inactive = try render(Sample(active: false), defaults: defaults)
            XCTAssertGreaterThan(inactive[0], 240)
            XCTAssertGreaterThan(inactive[1], 240)
            XCTAssertGreaterThan(inactive[2], 240)
        }
    }

    func testInvalidModeAndColorUseReadableDefaults() throws {
        try withDefaults { defaults in
            defaults.set("unknown", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            let original = try render(Sample(), defaults: defaults)
            XCTAssertGreaterThan(original[0], 240)
            XCTAssertGreaterThan(original[1], 240)
            defaults.set("custom", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set("invalid", forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            let fallback = try render(Sample(), defaults: defaults)
            defaults.set(PlayerAppearancePreferences.defaultCustomLyricsColorHex,
                         forKey: PlayerAppearancePreferences.customLyricsColorHexKey)
            XCTAssertEqual(fallback, try render(Sample(), defaults: defaults))
        }
    }

    func testGradientFollowsWritingDirection() throws {
        try withDefaults { defaults in
            defaults.set("gradient", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            defaults.set("FF0000", forKey: PlayerAppearancePreferences.gradientLyricsStartColorHexKey)
            defaults.set("0000FF", forKey: PlayerAppearancePreferences.gradientLyricsEndColorHexKey)
            let ltr = try render(Sample(), defaults: defaults)
            let rtl = try render(Sample(direction: .rightToLeft), defaults: defaults)
            XCTAssertGreaterThan(Int(ltr[0]), Int(ltr[2]) + 100)
            XCTAssertGreaterThan(Int(ltr[63 * 4 + 2]), Int(ltr[63 * 4]) + 100)
            XCTAssertGreaterThan(Int(rtl[2]), Int(rtl[0]) + 100)
            XCTAssertGreaterThan(Int(rtl[63 * 4]), Int(rtl[63 * 4 + 2]) + 100)
        }
    }

    func testWordHighlightUsesSelectedPaintAndKeepsUnsungWordsDim() throws {
        try withDefaults { defaults in
            let syllables = [TVSyllable(w: "MMMM ", start: 1, end: 2),
                             TVSyllable(w: "MMMM", start: 2, end: 3)]
            func line(at time: Double, style: AnyShapeStyle) -> some View {
                TVKaraokeLine(syllables: syllables, currentTime: time, size: 28, tint: .clear,
                              activeStyle: style, writingDirection: .leftToRight)
                    .background(Color.black)
            }
            func saturatedPixels(_ pixels: [UInt8], channel: Int) -> Int {
                stride(from: 0, to: pixels.count, by: 4).filter {
                    Int(pixels[$0 + channel]) > Int(pixels[$0 + 1]) + 80
                        && Int(pixels[$0 + channel]) > Int(pixels[$0 + (channel == 0 ? 2 : 0)]) + 30
                }.count
            }
            let before = try render(line(at: 0, style: AnyShapeStyle(Color.red)), defaults: defaults, width: 360, height: 70)
            XCTAssertEqual(saturatedPixels(before, channel: 0), 0)
            let sung = try render(line(at: 4, style: AnyShapeStyle(Color.red)), defaults: defaults, width: 360, height: 70)
            XCTAssertGreaterThan(saturatedPixels(sung, channel: 0), 200)
            let gradient = AnyShapeStyle(LinearGradient(colors: [.red, .blue], startPoint: .leading, endPoint: .trailing))
            let colored = try render(line(at: 4, style: gradient), defaults: defaults, width: 360, height: 70)
            XCTAssertGreaterThan(saturatedPixels(colored, channel: 0), 100)
            XCTAssertGreaterThan(saturatedPixels(colored, channel: 2), 100)
        }
    }

    func testColorSettingsPreview() throws {
        try withDefaults { defaults in
            defaults.set("gradient", forKey: PlayerAppearancePreferences.lyricsColorModeKey)
            let content = TVLyricsColorSettings().padding(40).frame(width: 1440)
                .background(TVColor.bg).defaultAppStorage(defaults).environment(\.colorScheme, .dark)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image)
            attachment.name = "TVLyricsColorSettings"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testColorPickerPreservesArbitrarySyncedColorAndFitsTV() async throws {
        let host = UIHostingController(rootView: TVLyricsColorPicker(
            titleKey: "player_lyrics_custom_color", selection: .constant("12AB34"),
            fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex, onDismiss: {}
        ).environment(\.colorScheme, .dark))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        window.rootViewController = host
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        host.view.layoutIfNeeded()
        func fields(in view: UIView) -> [UITextField] {
            if let field = view as? UITextField { return [field] }
            return view.subviews.flatMap { fields(in: $0) }
        }
        let field = try XCTUnwrap(fields(in: host.view).first)
        XCTAssertEqual(field.text, "12AB34")
        XCTAssertTrue(window.bounds.contains(field.convert(field.bounds, to: window)))
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "TVLyricsColorPicker"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "PlayerLyricsColorRenderingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    private func render<V: View>(_ view: V, defaults: UserDefaults, width: Int = 64, height: Int = 32) throws -> [UInt8] {
        let renderer = ImageRenderer(content: view.frame(width: CGFloat(width), height: CGFloat(height))
            .defaultAppStorage(defaults).environment(\.colorScheme, .light))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.cgImage)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return pixels
    }
}

#endif
