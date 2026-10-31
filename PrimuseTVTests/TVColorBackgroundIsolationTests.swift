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
#endif
