import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

final class PlayerLyricsColorPreferencesTests: XCTestCase {
    func testDefaultModePreservesExistingLyricsAppearance() {
        XCTAssertEqual(PlayerLyricsColorMode.defaultValue, .defaultColor)
        XCTAssertEqual(PlayerLyricsColorMode.defaultValue.rawValue, "default")
    }

    func testEveryInitialPickerColorIsValid() {
        let colors = [
            PlayerAppearancePreferences.defaultCustomLyricsColorHex,
            PlayerAppearancePreferences.defaultGradientLyricsStartColorHex,
            PlayerAppearancePreferences.defaultGradientLyricsEndColorHex,
        ]

        XCTAssertTrue(colors.allSatisfy(AppThemePreferences.isValidHex))
        XCTAssertNotEqual(colors[1], colors[2])
    }

    func testLyricsColorHexNormalizationAcceptsCommonInputFormats() {
        XCTAssertEqual(
            PlayerAppearancePreferences.normalizedLyricsColorHex(
                "  #ff375f  ",
                fallback: PlayerAppearancePreferences.defaultCustomLyricsColorHex
            ),
            "FF375F"
        )
    }

    func testLyricsColorHexNormalizationFallsBackFromInvalidStorage() {
        XCTAssertEqual(
            PlayerAppearancePreferences.normalizedLyricsColorHex(
                "not-a-color",
                fallback: PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
            ),
            PlayerAppearancePreferences.defaultGradientLyricsEndColorHex
        )
    }

    @MainActor
    func testWordLevelLyricsRenderOneContinuousGradient() throws {
        let line = LyricLine(
            timestamp: 0,
            text: "LEFT RIGHT",
            syllables: [
                LyricSyllable(text: "LEFT ", start: 0, end: 0.5),
                LyricSyllable(text: "RIGHT", start: 0.5, end: 1),
            ]
        )
        let content = KaraokeLineView(
            line: line,
            fontSize: 54,
            weight: .bold,
            activeStyle: AnyShapeStyle(
                LinearGradient(
                    colors: [.red, .blue],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            ),
            inactiveColor: .clear,
            timeAt: { _ in 2 },
            fixedTime: 2,
            animatesSyllableBounce: false
        )
        .frame(width: 360, height: 90, alignment: .leading)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        let pixels = try rgbaPixels(from: image)

        XCTAssertTrue(pixels.contains { $0.alpha > 40 && Int($0.red) - Int($0.blue) > 40 })
        XCTAssertTrue(pixels.contains { $0.alpha > 40 && Int($0.blue) - Int($0.red) > 40 })
    }

    private struct Pixel {
        let red: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private func rgbaPixels(from image: CGImage) throws -> [Pixel] {
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * image.height)
        let context = try XCTUnwrap(
            CGContext(
                data: &bytes,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return stride(from: 0, to: bytes.count, by: bytesPerPixel).map { offset in
            Pixel(red: bytes[offset], blue: bytes[offset + 2], alpha: bytes[offset + 3])
        }
    }
}
