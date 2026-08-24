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
#endif
