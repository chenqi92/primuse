import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

final class PlayerLyricsColorPreferencesTests: XCTestCase {
    func testLightAmbientOverlayKeepsDefaultAppearance() {
        let overlay = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: true,
            usesIncreasedContrast: false,
            strength: AppThemePreferences.defaultAmbientStrength
        )

        XCTAssertEqual(overlay.topOpacity, 0.24, accuracy: 0.000_001)
        XCTAssertEqual(overlay.bottomOpacity, 0.10, accuracy: 0.000_001)
    }

    func testLightAmbientOverlayRevealsMoreArtworkColorAtHigherStrength() {
        let neutral = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: true,
            usesIncreasedContrast: false,
            strength: 0
        )
        let vivid = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: true,
            usesIncreasedContrast: false,
            strength: 1
        )

        XCTAssertGreaterThan(neutral.topOpacity, vivid.topOpacity)
        XCTAssertGreaterThan(neutral.bottomOpacity, vivid.bottomOpacity)
    }

    func testLightAmbientOverlayPreservesIncreasedContrastFloor() {
        let standard = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: true,
            usesIncreasedContrast: false,
            strength: 1
        )
        let increased = AmbientLightOverlayPolicy.resolve(
            hasArtworkTheme: true,
            usesIncreasedContrast: true,
            strength: 1
        )

        XCTAssertGreaterThan(increased.topOpacity, standard.topOpacity)
        XCTAssertGreaterThan(increased.bottomOpacity, standard.bottomOpacity)
    }

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
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 360, height: 90, alignment: .leading)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        let pixels = try rgbaPixels(from: image)

        XCTAssertTrue(pixels.contains { $0.alpha > 40 && Int($0.red) - Int($0.blue) > 40 })
        XCTAssertTrue(pixels.contains { $0.alpha > 40 && Int($0.blue) - Int($0.red) > 40 })
    }

    @MainActor
    func testWordLevelHighlightWaitsForFirstSyllableTimestamp() throws {
        let line = LyricLine(
            timestamp: 0,
            text: "First",
            syllables: [
                LyricSyllable(text: "First", start: 3.1, end: 3.6),
            ]
        )
        let beforeStart = KaraokeLineView(
            line: line,
            fontSize: 54,
            weight: .bold,
            activeColor: .white,
            inactiveColor: .clear,
            timeAt: { _ in 0 },
            fixedTime: 0,
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 240, height: 90, alignment: .leading)
        let afterStart = KaraokeLineView(
            line: line,
            fontSize: 54,
            weight: .bold,
            activeColor: .white,
            inactiveColor: .clear,
            timeAt: { _ in 3.1 },
            fixedTime: 3.1,
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 240, height: 90, alignment: .leading)

        let beforeRenderer = ImageRenderer(content: beforeStart)
        beforeRenderer.scale = 1
        let afterRenderer = ImageRenderer(content: afterStart)
        afterRenderer.scale = 1
        let beforeImage = try XCTUnwrap(beforeRenderer.uiImage?.cgImage)
        let afterImage = try XCTUnwrap(afterRenderer.uiImage?.cgImage)

        XCTAssertEqual(try alphaCoverage(in: beforeImage), 0)
        XCTAssertGreaterThan(try alphaCoverage(in: afterImage), 0)
    }

    @MainActor
    func testRightToLeftSyllablesPreserveCompletePersianWords() throws {
        let syllableTexts = ["انگار ", "نه ", "از ", "یه ", "شهر ", "دور"]
        let text = syllableTexts.joined()
        let line = LyricLine(
            timestamp: 0,
            text: text,
            syllables: syllableTexts.enumerated().map { index, text in
                LyricSyllable(text: text, start: Double(index), end: Double(index + 1))
            }
        )
        let font = Font.system(size: 54, weight: .bold)
        let content = KaraokeLineView(
            line: line,
            fontSize: 54,
            weight: .bold,
            activeColor: .white,
            inactiveColor: .white,
            writingDirection: .rightToLeft,
            timeAt: { _ in 0 },
            fixedTime: 0,
            isAnimationEnabled: false,
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 620, height: 90)

        let reference = Text(text)
            .font(font)
            .foregroundStyle(.white)
            .fixedSize()
            .environment(\.layoutDirection, .rightToLeft)
            .frame(width: 620, height: 90)

        let contentRenderer = ImageRenderer(content: content)
        contentRenderer.scale = 3
        let referenceRenderer = ImageRenderer(content: reference)
        referenceRenderer.scale = 3
        let renderedImage = try XCTUnwrap(contentRenderer.uiImage?.cgImage)
        let referenceImage = try XCTUnwrap(referenceRenderer.uiImage?.cgImage)
        let renderedCoverage = try alphaCoverage(in: renderedImage)
        let referenceCoverage = try alphaCoverage(in: referenceImage)

        XCTAssertEqual(
            renderedCoverage,
            referenceCoverage,
            accuracy: referenceCoverage * 0.02,
            "RTL karaoke layout must render the complete Persian syllable instead of an ellipsis"
        )
    }

    @MainActor
    func testHighlightedPersianWordsMatchInactiveGlyphCoverageAcrossWrapping() throws {
        let syllableTexts = ["منو ", "عِشقای ", "چِرکی ", "Primuse ", "میتواند ", "بالعالم"]
        let line = LyricLine(
            timestamp: 0,
            text: syllableTexts.joined(),
            syllables: syllableTexts.enumerated().map { index, text in
                LyricSyllable(text: text, start: Double(index), end: Double(index + 1))
            }
        )
        let active = KaraokeLineView(
            line: line,
            fontSize: 42,
            weight: .bold,
            activeColor: .white,
            inactiveColor: .clear,
            writingDirection: .rightToLeft,
            timeAt: { _ in 10 },
            fixedTime: 10,
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 330, height: 150, alignment: .top)
        let inactive = KaraokeLineView(
            line: line,
            fontSize: 42,
            weight: .bold,
            activeColor: .clear,
            inactiveColor: .white,
            writingDirection: .rightToLeft,
            timeAt: { _ in 10 },
            fixedTime: 10,
            isAnimationEnabled: false,
            animatesSyllableBounce: false,
            isolatesAnimatedProgressFromLayout: true
        )
        .frame(width: 330, height: 150, alignment: .top)

        let activeRenderer = ImageRenderer(content: active)
        activeRenderer.scale = 3
        let inactiveRenderer = ImageRenderer(content: inactive)
        inactiveRenderer.scale = 3
        let activeImage = try XCTUnwrap(activeRenderer.uiImage?.cgImage)
        let inactiveImage = try XCTUnwrap(inactiveRenderer.uiImage?.cgImage)
        let activeCoverage = try alphaCoverage(in: activeImage)
        let inactiveCoverage = try alphaCoverage(in: inactiveImage)

        XCTAssertEqual(
            activeCoverage,
            inactiveCoverage,
            accuracy: inactiveCoverage * 0.02,
            "The active mask must not clip Persian, Arabic, or mixed-direction glyphs"
        )
    }

    @MainActor
    func testLyricFlowPlacementKeepsSubviewIdealWidth() throws {
        let content = LyricsFlowLayout(layoutDirection: .rightToLeft) {
            ProposalSensitiveGlyph {
                Color.white
            }
        }
        .frame(width: 100, height: 40, alignment: .topLeading)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)

        XCTAssertGreaterThanOrEqual(
            try alphaBoundingWidth(in: image),
            79,
            "Measured ideal width must not be replaced by a constrained placement proposal"
        )
    }

    private struct ProposalSensitiveGlyph: Layout {
        func sizeThatFits(
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) -> CGSize {
            CGSize(width: proposal.width == nil ? 80 : 20, height: 40)
        }

        func placeSubviews(
            in bounds: CGRect,
            proposal: ProposedViewSize,
            subviews: Subviews,
            cache: inout ()
        ) {
            for subview in subviews {
                subview.place(
                    at: bounds.origin,
                    anchor: .topLeading,
                    proposal: ProposedViewSize(bounds.size)
                )
            }
        }
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

    private func alphaCoverage(in image: CGImage) throws -> Double {
        let pixels = try rgbaPixels(from: image)
        return pixels.reduce(0) { $0 + Double($1.alpha) }
    }

    private func alphaBoundingWidth(in image: CGImage) throws -> Int {
        let pixels = try rgbaPixels(from: image)
        let occupiedColumns = pixels.enumerated().compactMap { index, pixel in
            pixel.alpha > 8 ? index % image.width : nil
        }
        let first = try XCTUnwrap(occupiedColumns.min())
        let last = try XCTUnwrap(occupiedColumns.max())
        return last - first + 1
    }
}
