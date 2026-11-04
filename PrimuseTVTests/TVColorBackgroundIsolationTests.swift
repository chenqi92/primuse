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
