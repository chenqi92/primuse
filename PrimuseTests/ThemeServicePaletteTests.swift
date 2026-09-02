import SwiftUI
import UIKit
import XCTest
@testable import Primuse

@MainActor
final class ThemeServicePaletteTests: XCTestCase {
    func testPaletteKeepsARepresentativeIndependentSecondaryColor() throws {
        let image = splitImage(
            primary: UIColor(hue: 0.01, saturation: 0.86, brightness: 0.78, alpha: 1),
            secondary: UIColor(hue: 0.64, saturation: 0.82, brightness: 0.72, alpha: 1),
            primaryFraction: 0.60
        )

        let result = try XCTUnwrap(ThemeService.extractDominantColor(from: image))
        let primaryHue = hue(of: result.accent)
        let secondaryHue = hue(of: result.secondary)

        XCTAssertLessThan(circularHueDistance(primaryHue, 0.01), 0.08)
        XCTAssertGreaterThan(circularHueDistance(primaryHue, secondaryHue), 0.25)
    }

    func testSmallNoiseRegionDoesNotBecomeTheSecondaryColor() throws {
        let image = splitImage(
            primary: UIColor(hue: 0.01, saturation: 0.86, brightness: 0.78, alpha: 1),
            secondary: UIColor(hue: 0.64, saturation: 0.90, brightness: 0.78, alpha: 1),
            primaryFraction: 0.98
        )

        let result = try XCTUnwrap(ThemeService.extractDominantColor(from: image))

        XCTAssertLessThan(
            circularHueDistance(hue(of: result.accent), hue(of: result.secondary)),
            0.08
        )
    }

    func testPaletteLuminanceUsesArtworkPixelsRatherThanHSVBrightness() throws {
        let yellow = solidImage(
            UIColor(hue: 0.16, saturation: 0.80, brightness: 0.75, alpha: 1)
        )
        let blue = solidImage(
            UIColor(hue: 0.64, saturation: 0.80, brightness: 0.75, alpha: 1)
        )

        let yellowResult = try XCTUnwrap(ThemeService.extractDominantColor(from: yellow))
        let blueResult = try XCTUnwrap(ThemeService.extractDominantColor(from: blue))

        XCTAssertGreaterThan(yellowResult.luminance, blueResult.luminance + 0.20)
    }

    func testPaletteVibrancyTracksArtworkSaturation() throws {
        let muted = solidImage(
            UIColor(hue: 0.56, saturation: 0.30, brightness: 0.70, alpha: 1)
        )
        let vivid = solidImage(
            UIColor(hue: 0.56, saturation: 0.86, brightness: 0.70, alpha: 1)
        )

        let mutedResult = try XCTUnwrap(ThemeService.extractDominantColor(from: muted))
        let vividResult = try XCTUnwrap(ThemeService.extractDominantColor(from: vivid))

        XCTAssertGreaterThan(vividResult.vibrancy, mutedResult.vibrancy)
    }

    func testImmersiveSecondarySurfaceStaysDarkForBrightArtwork() throws {
        let image = splitImage(
            primary: UIColor(hue: 0.01, saturation: 0.86, brightness: 0.78, alpha: 1),
            secondary: UIColor(hue: 0.16, saturation: 0.90, brightness: 0.90, alpha: 1),
            primaryFraction: 0.60
        )

        let result = try XCTUnwrap(ThemeService.extractDominantColor(from: image))

        XCTAssertLessThanOrEqual(brightness(of: result.secondaryDark), 0.281)
        XCTAssertGreaterThan(
            circularHueDistance(hue(of: result.accent), hue(of: result.secondaryDark)),
            0.08
        )
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        splitImage(primary: color, secondary: color, primaryFraction: 1)
    }

    private func splitImage(
        primary: UIColor,
        secondary: UIColor,
        primaryFraction: CGFloat
    ) -> UIImage {
        let size = CGSize(width: 80, height: 80)
        return UIGraphicsImageRenderer(size: size).image { context in
            context.cgContext.setFillColor(primary.cgColor)
            context.cgContext.fill(CGRect(
                x: 0,
                y: 0,
                width: size.width * primaryFraction,
                height: size.height
            ))
            context.cgContext.setFillColor(secondary.cgColor)
            context.cgContext.fill(CGRect(
                x: size.width * primaryFraction,
                y: 0,
                width: size.width * (1 - primaryFraction),
                height: size.height
            ))
        }
    }

    private func hue(of color: Color) -> CGFloat {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ))
        return hue
    }

    private func brightness(of color: Color) -> CGFloat {
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        XCTAssertTrue(UIColor(color).getHue(
            &hue,
            saturation: &saturation,
            brightness: &brightness,
            alpha: &alpha
        ))
        return brightness
    }

    private func circularHueDistance(_ lhs: CGFloat, _ rhs: CGFloat) -> CGFloat {
        let distance = abs(lhs - rhs)
        return min(distance, 1 - distance)
    }
}

@MainActor
final class MainActorNotificationRelayTests: XCTestCase {
    func testSelectorDeliveryFromBackgroundQueueHopsToMainActor() async {
        let name = Notification.Name("MainActorNotificationRelayTests.delivery")
        let subject = NotificationRelayTestSubject()
        let delivered = expectation(description: "notification delivered on main actor")
        let relay = MainActorNotificationRelay { delivery in
            MainActor.assertIsolated()
            XCTAssertEqual(delivery.name, name)
            XCTAssertEqual(delivery.objectIdentifier, ObjectIdentifier(subject))
            delivered.fulfill()
        }

        NotificationCenter.default.addObserver(
            relay,
            selector: #selector(MainActorNotificationRelay.receive(_:)),
            name: name,
            object: subject
        )
        defer { NotificationCenter.default.removeObserver(relay) }

        DispatchQueue.global(qos: .userInitiated).async {
            NotificationCenter.default.post(name: name, object: subject)
        }

        await fulfillment(of: [delivered], timeout: 2)
    }
}

private final class NotificationRelayTestSubject: NSObject, @unchecked Sendable {}
