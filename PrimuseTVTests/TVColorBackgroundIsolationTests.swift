#if os(tvOS)
import UIKit
import XCTest
@testable import PrimuseTV

final class TVColorBackgroundIsolationTests: XCTestCase {
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
