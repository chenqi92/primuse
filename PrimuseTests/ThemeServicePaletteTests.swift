import SwiftUI
import UIKit
import PrimuseKit
import XCTest
@testable import Primuse

@MainActor
final class ThemeServicePaletteTests: XCTestCase {
    func testArtistMeshPreservesMultipleColorsAndWhiteTextContrast() {
        let palette = [LiquidBackdropColor(red: 0.98, green: 0.9, blue: 0.4),
                       LiquidBackdropColor(red: 0.1, green: 0.2, blue: 0.9),
                       LiquidBackdropColor(red: 0.9, green: 0.1, blue: 0.4)]
        let result = LibraryDetailTintStyle.artworkBackground(
            .gray, palette: palette, ambientStyle: .mesh, colorScheme: .light
        )
        XCTAssertEqual(result.meshColors.count, 9)
        XCTAssertGreaterThanOrEqual(Set(result.meshColors).count, 3)
        for color in result.meshColors {
            var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            XCTAssertTrue(UIColor(color).getHue(&h, saturation: &s, brightness: &b, alpha: &a))
            let stop = LibraryDetailTintStop(hue: h, saturation: s, brightness: b)
            XCTAssertGreaterThanOrEqual(LibraryDetailTintPolicy.contrastRatioAgainstWhite(stop), 4.5 - 0.001)
        }
    }

    func testArtistClassicAndSingleColorKeepContinuousBackground() {
        let palette = [LiquidBackdropColor(red: 1, green: 0, blue: 0),
                       LiquidBackdropColor(red: 0, green: 1, blue: 0)]
        let classic = LibraryDetailTintStyle.artworkBackground(
            .blue, palette: palette, ambientStyle: .classic, colorScheme: .dark
        )
        let singleColor = LibraryDetailTintStyle.artworkBackground(
            .blue, palette: [], ambientStyle: .mesh, colorScheme: .dark
        )
        XCTAssertTrue(classic.meshColors.isEmpty)
        XCTAssertEqual(classic, singleColor)
    }

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

    func testMostlyWhiteCoverUsesItsSmallFullBrightnessColor() throws {
        let image = splitImage(
            primary: .white,
            secondary: UIColor(red: 1, green: 0, blue: 0, alpha: 1),
            primaryFraction: 0.96
        )

        let result = try XCTUnwrap(ThemeService.extractDominantColor(from: image))

        XCTAssertLessThan(circularHueDistance(hue(of: result.accent), 0), 0.04)
    }

    func testPastelCoverUsesItsOwnHueInsteadOfGray() throws {
        let image = solidImage(UIColor(hue: 0.37, saturation: 0.11, brightness: 0.93, alpha: 1))

        let result = try XCTUnwrap(ThemeService.extractDominantColor(from: image))

        XCTAssertLessThan(circularHueDistance(hue(of: result.accent), 0.37), 0.04)
    }

    func testGrayscaleCoverStillHasNoAccent() {
        let image = splitImage(primary: .white, secondary: .darkGray, primaryFraction: 0.5)

        XCTAssertNil(ThemeService.extractDominantColor(from: image))
    }

    func testPortraitBackgroundKeepsDarkSurroundingsInsteadOfSkinTone() throws {
        let image = splitImage(primary: UIColor(white: 0.07, alpha: 1),
                               secondary: UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1),
                               primaryFraction: 0.75)
        let color = try XCTUnwrap(ThemeService.extractBackgroundColor(from: image))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertLessThan(max(r, g, b), 0.1)
        XCTAssertEqual(r, g, accuracy: 0.01)
        XCTAssertEqual(g, b, accuracy: 0.01)
    }

    func testPortraitBackgroundKeepsMutedBlueInsteadOfWarmForeground() throws {
        let image = splitImage(primary: UIColor(red: 0.24, green: 0.27, blue: 0.30, alpha: 1),
                               secondary: UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1),
                               primaryFraction: 0.75)
        let color = try XCTUnwrap(ThemeService.extractBackgroundColor(from: image))
        XCTAssertLessThan(circularHueDistance(hue(of: color), 0.583), 0.04)
        XCTAssertEqual(brightness(of: color), 0.30, accuracy: 0.02)
    }

    func testWarmGrayBackgroundIsNotMadeMoreSaturated() throws {
        let image = solidImage(UIColor(red: 0.40, green: 0.38, blue: 0.36, alpha: 1))
        let extracted = try XCTUnwrap(ThemeService.extractBackgroundColor(from: image))
        let style = LibraryDetailTintStyle.artworkBackground(extracted, colorScheme: .light)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(style.top).getHue(&h, saturation: &s, brightness: &b, alpha: &a))
        XCTAssertEqual(s, 0.10, accuracy: 0.02)
        XCTAssertEqual(b, 0.40, accuracy: 0.02)
    }

    func testPortraitBackgroundExtendsTexturedGrayLowerEdgeInsteadOfSkinTone() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 80)).image { context in
            UIColor(red: 0.8, green: 0.5, blue: 0.3, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 80, height: 80))
            for x in 0..<80 {
                UIColor(white: 0.25 + CGFloat(x) / 160, alpha: 1).setFill()
                context.fill(CGRect(x: x, y: 40, width: 1, height: 40))
            }
        }
        let color = try XCTUnwrap(ThemeService.extractBackgroundColor(from: image))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        XCTAssertTrue(UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a))
        XCTAssertEqual(r, g, accuracy: 0.01)
        XCTAssertEqual(g, b, accuracy: 0.01)
        XCTAssertEqual(r, 0.50, accuracy: 0.03)
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
