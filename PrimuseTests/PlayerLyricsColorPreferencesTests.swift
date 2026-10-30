import Foundation
import PrimuseKit
import SwiftUI
import UIKit
import XCTest
@testable import Primuse

final class PlayerLyricsColorPreferencesTests: XCTestCase {
    func testLyricsPulseIsSelectableWithoutChangingExistingPreferences() {
        XCTAssertEqual(PlayerLyricsMotion.allCases.map(\.rawValue), ["standard", "cascade", "pulse"])
        XCTAssertEqual(PlayerLyricsMotion.defaultValue, .standard)
        XCTAssertEqual(PlayerLyricsMotion(rawValue: "standard"), .standard)
        XCTAssertEqual(PlayerLyricsMotion(rawValue: "cascade"), .cascade)
        XCTAssertEqual(PlayerLyricsMotion(rawValue: "pulse"), .pulse)
    }

    func testTransportIconStylesFallBackToTheOriginalLook() {
        XCTAssertEqual(PlayerAppearancePreferences.playButtonStyle(rawValue: ""), .filledCircle)
        XCTAssertEqual(PlayerAppearancePreferences.playButtonStyle(rawValue: "sparkly"), .filledCircle)
        XCTAssertEqual(PlayerAppearancePreferences.skipButtonStyle(rawValue: ""), .standard)
        XCTAssertEqual(NowPlayingSkipButtonStyle.standard.symbol(forward: false), "backward.fill")
        XCTAssertEqual(NowPlayingSkipButtonStyle.standard.symbol(forward: true), "forward.fill")
        // 存进设置的是原始值,改名就丢了用户选的样式。
        XCTAssertEqual(
            NowPlayingPlayButtonStyle.allCases.map(\.rawValue),
            ["filledCircle", "plain", "outlinedCircle", "filledSquare", "largePlain"]
        )
        // 只有「大号无框」让上一首 / 下一首跟着放大,别的样式还是原来的字号。
        for style in NowPlayingPlayButtonStyle.allCases {
            XCTAssertEqual(NowPlayingSkipButtonStyle.pairingScale(with: style) > 1, style == .largePlain, style.rawValue)
        }
        XCTAssertGreaterThan(NowPlayingPlayPauseFace.largePlainGlyphScale, NowPlayingPlayPauseFace.plainGlyphScale)
        // 音量条默认还是系统样式;存的原始值改名就丢了用户的选择。
        XCTAssertEqual(PlayerAppearancePreferences.volumeBarStyle(rawValue: ""), .system)
        XCTAssertEqual(NowPlayingVolumeBarStyle.allCases.map(\.rawValue), ["system", "matchesProgress"])
        // 「跟进度条一致」照抄进度条的粗细、圆点与波浪,按住时也一样加粗。
        let dot = PlayerVolumeTrackStyle.matching(.forProgressStyle(.dot, glows: true))
        XCTAssertEqual(dot.restingHeight, 3)
        XCTAssertEqual(dot.activeHeight, 6)
        XCTAssertEqual(dot.knobDiameter, 12)
        XCTAssertTrue(dot.glows)
        XCTAssertTrue(PlayerVolumeTrackStyle.matching(.forProgressStyle(.wave)).isWave)
        XCTAssertNil(PlayerVolumeTrackStyle.matching(.forProgressStyle(.standard)).knobDiameter)
        XCTAssertGreaterThan(PlayerVolumeTrackStyle.system.height(isActive: true, reduceMotion: false), PlayerVolumeTrackStyle.system.restingHeight)
        XCTAssertEqual(
            NowPlayingSkipButtonStyle.allCases.map(\.rawValue),
            ["standard", "bold", "track", "filledCircle", "outlinedCircle"]
        )
        for style in NowPlayingSkipButtonStyle.allCases {
            // 上一首、下一首是一对:同一种写法,只是方向相反。
            XCTAssertEqual(
                style.symbol(forward: false).replacingOccurrences(of: "backward", with: "forward"),
                style.symbol(forward: true)
            )
            // 手机横屏那两颗自己有玻璃胶囊,不再套圆。
            XCTAssertFalse(style.glyphSymbol(forward: false).contains("circle"))
            XCTAssertFalse(style.glyphSymbol(forward: true).contains("circle"))
        }
    }

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
    func testInactiveLyricsBlurRendersAcrossScriptsAndTimingFormats() throws {
        let samples: [(String, [String])] = [
            ("simplified", Array("风吹过窗前的树叶").map(String.init)),
            ("traditional", Array("風吹過窗前的樹葉").map(String.init)),
            ("english", ["Wind ", "passes ", "my ", "window"]),
        ]
        let radius = LyricDepthEffectPolicy.blurRadius(
            forRow: 3, activeRow: 1, isEnabled: true, isSynchronized: true
        )
        for locale in ["zh-Hans", "zh-Hant", "en"] {
            for (script, words) in samples {
                for wordTimed in [false, true] {
                    let line = LyricLine(
                        timestamp: 10,
                        text: words.joined(),
                        syllables: wordTimed ? words.enumerated().map { index, text in
                            LyricSyllable(text: text, start: 10 + Double(index), end: 11 + Double(index))
                        } : nil
                    )
                    func render(blur: Double) throws -> CGImage {
                        let content = Group {
                            if wordTimed {
                                KaraokeLineView(
                                    line: line,
                                    fontSize: 26,
                                    weight: .semibold,
                                    activeColor: .white,
                                    inactiveColor: .white,
                                    timeAt: { _ in 0 },
                                    fixedTime: 0,
                                    isPlaybackActive: false,
                                    isAnimationEnabled: false,
                                    animatesSyllableBounce: false
                                )
                            } else {
                                Text(line.text)
                                    .font(.system(size: 26, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .frame(width: 280, alignment: .leading)
                        .opacity(0.4)
                        .blur(radius: blur)
                        .padding(20)
                        .frame(width: 340, height: 140)
                        .environment(\.locale, Locale(identifier: locale))
                        let renderer = ImageRenderer(content: content)
                        renderer.scale = 1
                        return try XCTUnwrap(renderer.uiImage?.cgImage)
                    }
                    let sharp = try rgbaPixels(from: render(blur: 0))
                    let blurred = try rgbaPixels(from: render(blur: radius))
                    let label = "\(locale) / \(script) / \(wordTimed ? "word" : "line")"
                    let sharpInk = sharp.filter { $0.alpha > 5 }.count
                    let blurredInk = blurred.filter { $0.alpha > 5 }.count
                    XCTAssertGreaterThan(sharpInk, 100, label)
                    XCTAssertGreaterThan(blurredInk, sharpInk, "Blur must spread glyph edges: " + label)
                    XCTAssertLessThan(
                        try XCTUnwrap(blurred.map(\.alpha).max()),
                        try XCTUnwrap(sharp.map(\.alpha).max()),
                        "Blur must soften glyph peaks: " + label
                    )
                }
            }
        }
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

    @MainActor
    func testKaraokeDeferredLayoutSurvivesLyricsClearingAndReplacement() throws {
        var snapshot = KaraokeLyricsSnapshot(lines: [
            LyricLine(id: "old-first", timestamp: 1, text: "First line"),
            LyricLine(id: "old-last", timestamp: 10, text: "Last line"),
        ])
        let stage = KaraokeLyricsStage(snapshot: snapshot, part: .all, time: 11, isPlaying: false)
        let deferredLayout = stage.body
        snapshot = KaraokeLyricsSnapshot()
        snapshot = KaraokeLyricsSnapshot(lines: [LyricLine(id: "new", timestamp: 1, text: "New")])

        let renderer = ImageRenderer(content: deferredLayout.frame(width: 360, height: 240))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        XCTAssertGreaterThan(try alphaCoverage(in: image), 100)
        XCTAssertEqual(snapshot.lines.count, 1)
    }

    @MainActor
    func testKaraokeEmptySnapshotRendersAfterStageWasCreated() throws {
        let stage = KaraokeLyricsStage(snapshot: KaraokeLyricsSnapshot(), part: .all, time: 11, isPlaying: false)
        let renderer = ImageRenderer(content: stage.frame(width: 360, height: 240))
        renderer.scale = 1
        let image = try XCTUnwrap(renderer.uiImage?.cgImage)
        XCTAssertEqual(try alphaCoverage(in: image), 0)
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

final class PlaybackSettingsLockScreenLyricsTests: XCTestCase {
    func testNewPlaybackSettingsEnableLockScreenLyrics() {
        XCTAssertTrue(PlaybackSettings().lockScreenLyricsEnabled)
    }

    func testRolloutEnablesExistingDisabledSettingOnlyOnce() throws {
        let suiteName = "PlaybackSettingsLockScreenLyricsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var existing = PlaybackSettings()
        existing.lockScreenLyricsEnabled = false
        existing.save(defaults: defaults)

        XCTAssertTrue(PlaybackSettings.applyLockScreenLyricsRolloutIfNeeded(defaults: defaults))
        XCTAssertTrue(PlaybackSettings.load(defaults: defaults).lockScreenLyricsEnabled)

        var optedOut = PlaybackSettings.load(defaults: defaults)
        optedOut.lockScreenLyricsEnabled = false
        optedOut.save(defaults: defaults)

        XCTAssertFalse(PlaybackSettings.applyLockScreenLyricsRolloutIfNeeded(defaults: defaults))
        XCTAssertFalse(PlaybackSettings.load(defaults: defaults).lockScreenLyricsEnabled)
    }
}

final class PlaybackSettingsCrossfadeDurationTests: XCTestCase {
    func testNewPlaybackSettingsUseCurrentDefaultDuration() {
        XCTAssertEqual(PlaybackSettings().crossfadeDuration, PlaybackSettings.defaultCrossfadeDuration)
    }

    func testRolloutMovesUnusedLegacyDefaultOnlyOnce() throws {
        let suiteName = "PlaybackSettingsCrossfadeDurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var existing = PlaybackSettings()
        existing.crossfadeDuration = PlaybackSettings.legacyDefaultCrossfadeDuration
        existing.save(defaults: defaults)

        XCTAssertTrue(PlaybackSettings.applyCrossfadeDurationRolloutIfNeeded(defaults: defaults))
        XCTAssertEqual(
            PlaybackSettings.load(defaults: defaults).crossfadeDuration,
            PlaybackSettings.defaultCrossfadeDuration
        )

        var chosen = PlaybackSettings.load(defaults: defaults)
        chosen.crossfadeDuration = PlaybackSettings.legacyDefaultCrossfadeDuration
        chosen.save(defaults: defaults)

        XCTAssertFalse(PlaybackSettings.applyCrossfadeDurationRolloutIfNeeded(defaults: defaults))
        XCTAssertEqual(
            PlaybackSettings.load(defaults: defaults).crossfadeDuration,
            PlaybackSettings.legacyDefaultCrossfadeDuration
        )
    }

    func testRolloutKeepsDurationChosenWhileCrossfadeIsOn() throws {
        let suiteName = "PlaybackSettingsCrossfadeDurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var existing = PlaybackSettings()
        existing.crossfadeEnabled = true
        existing.crossfadeDuration = PlaybackSettings.legacyDefaultCrossfadeDuration
        existing.save(defaults: defaults)

        XCTAssertFalse(PlaybackSettings.applyCrossfadeDurationRolloutIfNeeded(defaults: defaults))
        XCTAssertEqual(
            PlaybackSettings.load(defaults: defaults).crossfadeDuration,
            PlaybackSettings.legacyDefaultCrossfadeDuration
        )
    }
}

/// 「播放页样式与按钮」的一键套用:写进去的是这一套,打得上勾,恢复后和套用前一模一样。
@MainActor
final class NowPlayingStylePresetTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "NowPlayingStylePresetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testConcisePresetWritesItsLookAndRestoresTheOldOne() {
        let defaults = makeDefaults()
        let backdrop = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        // 套用前:改过播放键,随机键挪到了底栏,其余没碰过。
        defaults.set(NowPlayingPlayButtonStyle.outlinedCircle.rawValue, forKey: PlayerAppearancePreferences.playButtonStyleKey)
        let customLayout = NowPlayingControlLayout.default.placing(.shuffle, at: .bar(3))
        defaults.set(customLayout.encoded(), forKey: NowPlayingControlLayout.musicStorageKey)
        let before = NowPlayingStylePresetApplier.snapshot(defaults: defaults, backdrop: backdrop)

        XCTAssertFalse(NowPlayingStylePreset.concise.matches(defaults: defaults, backdropSource: backdrop.settings.source))
        NowPlayingStylePresetApplier.apply(.concise, defaults: defaults, backdrop: backdrop)

        XCTAssertTrue(NowPlayingStylePreset.concise.matches(defaults: defaults, backdropSource: backdrop.settings.source))
        XCTAssertFalse(NowPlayingStylePreset.standard.matches(defaults: defaults, backdropSource: backdrop.settings.source))
        XCTAssertEqual(defaults.string(forKey: PlayerAppearancePreferences.playButtonStyleKey), "largePlain")
        XCTAssertEqual(defaults.object(forKey: PlayerAppearancePreferences.showsAlbumInSubtitleKey) as? Bool, false)
        XCTAssertEqual(backdrop.settings.source, .liquid)
        let layout = NowPlayingControlLayout.decode(defaults.string(forKey: NowPlayingControlLayout.musicStorageKey) ?? "")
        XCTAssertNil(layout.action(in: .leadingEdge))
        XCTAssertNil(layout.action(in: .trailingEdge))
        XCTAssertEqual(layout.action(in: .header), .like)
        XCTAssertEqual(layout.bar, NowPlayingControlLayout.defaultBar)
        XCTAssertNotNil(defaults.string(forKey: NowPlayingStylePresetSnapshot.storageKey))

        NowPlayingStylePresetApplier.restore(defaults: defaults, backdrop: backdrop)
        XCTAssertEqual(NowPlayingStylePresetApplier.snapshot(defaults: defaults, backdrop: backdrop), before)
        XCTAssertEqual(backdrop.settings.source, .coverAmbient)
        // 没存过的键恢复后照样没存(以后改默认也跟得上)。
        XCTAssertNil(defaults.object(forKey: PlayerAppearancePreferences.volumeBarStyleKey))
        XCTAssertNil(defaults.string(forKey: NowPlayingStylePresetSnapshot.storageKey))
    }

    func testBoolStoredAsStringStillMatches() {
        let defaults = makeDefaults()
        let backdrop = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        NowPlayingStylePresetApplier.apply(.concise, defaults: defaults, backdrop: backdrop)
        // 启动参数 `-primuse.player.showsAlbumInSubtitle NO` 进来的是字符串,播放页照样当成关。
        defaults.set("NO", forKey: PlayerAppearancePreferences.showsAlbumInSubtitleKey)
        XCTAssertTrue(NowPlayingStylePreset.concise.matches(defaults: defaults, backdropSource: backdrop.settings.source))
    }

    func testUntouchedSettingsAreTheDefaultPreset() {
        let defaults = makeDefaults()
        let backdrop = PlayerBackdropSettingsStore(defaults: defaults, registersWithCloud: false)
        XCTAssertTrue(NowPlayingStylePreset.standard.matches(defaults: defaults, backdropSource: backdrop.settings.source))
        XCTAssertEqual(Set(NowPlayingStylePreset.concise.values.keys), Set(NowPlayingStylePreset.defaultValues.keys))
    }
}

@MainActor
final class SystemVolumeSliderTests: XCTestCase {
    private final class VolumeView: PlayerSystemVolumeView {
        var testSlider: UISlider?
        override var volumeSlider: UISlider? { testSlider }

        func installSlider(value: Float = 0.25) -> UISlider {
            testSlider?.removeFromSuperview()
            let slider = UISlider(frame: bounds)
            slider.value = value
            let thumb = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { _ in }
            slider.setThumbImage(thumb, for: .normal)
            slider.setThumbImage(thumb, for: .highlighted)
            addSubview(slider)
            testSlider = slider
            setNeedsLayout()
            return slider
        }
    }

    private func key(
        style: PlayerVolumeTrackStyle = .matching(.standard), reduceMotion: Bool = true
    ) -> SystemVolumeSlider.StyleKey {
        SystemVolumeSlider.StyleKey(
            isLight: false, usesIncreasedContrast: false, trackStyle: style,
            fillTint: .white, reduceMotion: reduceMotion
        )
    }

    func testRealSystemVolumeViewKeepsItsNativeSliderAndTransparentImages() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        let controller = UIViewController()
        window.rootViewController = controller
        let view = PlayerSystemVolumeView(frame: CGRect(x: 24, y: 200, width: 300, height: 24))
        view.showsVolumeSlider = true
        controller.view.addSubview(view)
        let coordinator = SystemVolumeSlider.Coordinator()
        defer {
            coordinator.detach()
            window.isHidden = true
            originalWindow?.makeKeyAndVisible()
        }
        coordinator.configure(in: view, styleKey: key())
        window.makeKeyAndVisible()
        for _ in 0..<30 {
            view.setNeedsLayout()
            view.layoutIfNeeded()
            if view.volumeSlider != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }

        #if targetEnvironment(simulator)
        try XCTSkipIf(view.volumeSlider == nil, "iOS 模拟器不提供真实系统音量滑块；保留真机回归用例。")
        #endif
        let slider = try XCTUnwrap(view.volumeSlider,
            "window=\(window.bounds), view=\(view.frame), showsVolumeSlider=\(view.showsVolumeSlider), children=\(view.subviews.map { String(describing: type(of: $0)) })")
        XCTAssertTrue(coordinator.slider === slider)
        XCTAssertTrue(slider.isUserInteractionEnabled)
        XCTAssertFalse(view.trackView.isUserInteractionEnabled)
        XCTAssertFalse(view.trackView.isHidden)
        XCTAssertGreaterThan(view.trackView.bounds.height, view.bounds.height)
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            let track = try XCTUnwrap(view.maximumVolumeSliderImage(for: state))
            XCTAssertTrue(try pixels(of: track).allSatisfy { $0 == 0 })
        }
    }

    func testSliderCreatedAfterInitialConfigurationIsStyledOnLayout() throws {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        coordinator.configure(in: view, styleKey: key())
        XCTAssertNil(coordinator.slider)
        XCTAssertTrue(view.trackView.isHidden)

        let slider = view.installSlider()
        view.layoutIfNeeded()

        XCTAssertTrue(coordinator.slider === slider)
        XCTAssertFalse(view.trackView.isHidden)
        for state: UIControl.State in [.normal, .highlighted, .disabled] {
            XCTAssertNotNil(view.minimumVolumeSliderImage(for: state))
            XCTAssertNotNil(view.maximumVolumeSliderImage(for: state))
            XCTAssertNotNil(view.volumeThumbImage(for: state))
        }
        XCTAssertTrue(try pixels(of: render(view.trackView)).contains { $0 > 0 })
    }

    func testReplacingSliderMovesInteractionToTheNewControlWithoutAStyleChange() {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let oldSlider = view.installSlider()
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        coordinator.configure(in: view, styleKey: key())
        view.layoutIfNeeded()

        let replacement = view.installSlider(value: 0.7)
        view.layoutIfNeeded()
        XCTAssertTrue(coordinator.slider === replacement)
        oldSlider.sendActions(for: .touchDown)
        XCTAssertFalse(view.trackView.isActive)
        replacement.sendActions(for: .touchDown)
        XCTAssertTrue(view.trackView.isActive)
        replacement.sendActions(for: .touchCancel)
        XCTAssertFalse(view.trackView.isActive)
    }

    func testEmptyTrackSurvivesNativeTrackResetAndPressReleaseCycles() throws {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let slider = view.installSlider()
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        coordinator.configure(in: view, styleKey: key())
        view.layoutIfNeeded()
        let nativeTrack = slider.trackRect(forBounds: slider.bounds)
        let maximum = slider.thumbRect(forBounds: slider.bounds, trackRect: nativeTrack, value: 1)
        let sampleX = Int(maximum.midX - 30)
        let sampleY = Int(view.bounds.midY)

        for _ in 0..<3 {
            slider.setMaximumTrackImage(nil, for: .normal)
            slider.setMaximumTrackImage(nil, for: .highlighted)
            slider.maximumTrackTintColor = .clear
            for event: UIControl.Event in [.touchDown, .touchUpInside, .touchDown, .touchCancel] {
                slider.sendActions(for: event)
                let image = render(view.trackView)
                let bytes = try pixels(of: image)
                XCTAssertGreaterThan(bytes[(sampleY * 300 + sampleX) * 4 + 3], 30)
            }
        }
    }

    func testVolumeCapsulesMatchProgressRenderingAtZeroLowMiddleAndFullValues() throws {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let slider = view.installSlider()
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        var style = PlayerVolumeTrackStyle.matching(.standard)
        style.trackColor = .blue.opacity(0.3)
        coordinator.configure(in: view, styleKey: key(style: style))
        view.layoutIfNeeded()
        let nativeTrack = slider.trackRect(forBounds: slider.bounds)
        let minimum = slider.thumbRect(forBounds: slider.bounds, trackRect: nativeTrack, value: 0)
        let maximum = slider.thumbRect(forBounds: slider.bounds, trackRect: nativeTrack, value: 1)
        let width = maximum.midX - minimum.midX

        for reduceMotion in [false, true] {
            coordinator.configure(in: view, styleKey: key(style: style, reduceMotion: reduceMotion))
            for scale: CGFloat in [1, 3] {
                for active in [false, true] {
                    slider.sendActions(for: active ? .touchDown : .touchCancel)
                    let height = style.height(isActive: active, reduceMotion: reduceMotion)
                    for fraction: Float in [0, 0.01, 0.5, 1] {
                        slider.value = fraction
                        coordinator.synchronizeSlider()
                        let actual = render(view.trackView, scale: scale)
                        let reference = ImageRenderer(content:
                            ZStack(alignment: .topLeading) {
                                Capsule().fill(Color.blue.opacity(0.3))
                                    .frame(width: width, height: height)
                                Capsule().fill(Color.white)
                                    .frame(width: width * CGFloat(fraction), height: height)
                            }
                            .offset(x: minimum.midX, y: view.bounds.midY - height / 2)
                            .frame(width: 300, height: 24, alignment: .topLeading)
                        )
                        reference.scale = scale
                        let expected = try XCTUnwrap(reference.uiImage)
                        let actualPixels = try pixels(of: actual)
                        let expectedPixels = try pixels(of: expected)
                        XCTAssertEqual(actualPixels.count, expectedPixels.count)
                        let totalDifference = zip(actualPixels, expectedPixels).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                        let paintedPixels = stride(from: 3, to: expectedPixels.count, by: 4).filter { expectedPixels[$0] > 0 }.count
                        XCTAssertLessThan(Double(totalDifference) / Double(max(1, paintedPixels * 4)), 3,
                                          "scale=\(scale), reduceMotion=\(reduceMotion), active=\(active), volume=\(fraction)")
                        if fraction == 0.5, scale == 3, !reduceMotion {
                            for (name, image) in [("volume", actual), ("progress-reference", expected)] {
                                let attachment = XCTAttachment(image: image)
                                attachment.name = "\(name)-capsule-\(active ? "pressed" : "resting")"
                                attachment.lifetime = .keepAlways
                                add(attachment)
                            }
                        }
                    }
                }
            }
        }
    }

    func testAllStylesKeepTheirEmptyTrackWhenResizedAndReturnFromCancelledDrag() throws {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let slider = view.installSlider(value: 0.2)
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        let styles: [PlayerVolumeTrackStyle] = [
            .system, .matching(.standard), .matching(.forProgressStyle(.dot, glows: true)),
            .matching(.forProgressStyle(.wave, glows: true))
        ]
        for style in styles {
            coordinator.configure(in: view, styleKey: key(style: style))
            for width: CGFloat in [180, 420] {
                view.frame.size.width = width
                slider.frame = view.bounds
                view.setNeedsLayout()
                view.layoutIfNeeded()
                slider.sendActions(for: .touchDown)
                slider.sendActions(for: .touchCancel)
                XCTAssertFalse(view.trackView.isActive)
                let rect = slider.trackRect(forBounds: slider.bounds)
                let end = slider.thumbRect(forBounds: slider.bounds, trackRect: rect, value: 1)
                let bytes = try pixels(of: render(view.trackView))
                XCTAssertGreaterThan(bytes[(Int(view.bounds.midY) * Int(width) + Int(end.midX - 30)) * 4 + 3], 30)
            }
        }
    }

    func testTrackAndKnobStayCenteredWhenNativeSliderLayoutChanges() throws {
        let view = VolumeView(frame: CGRect(x: 0, y: 0, width: 300, height: 24))
        let slider = view.installSlider(value: 0.5)
        let coordinator = SystemVolumeSlider.Coordinator()
        defer { coordinator.detach() }
        coordinator.configure(in: view, styleKey: key(style: .system))
        view.layoutIfNeeded()

        for width: CGFloat in [180, 300, 420] {
            view.frame.size.width = width
            for nativeFrame in [
                CGRect(x: 0, y: -6, width: width, height: 31),
                CGRect(x: 0, y: 3, width: width, height: 24)
            ] {
                slider.frame = nativeFrame
                view.setNeedsLayout()
                view.layoutIfNeeded()
                for event: UIControl.Event in [.touchDown, .touchUpInside, .touchCancel] {
                    slider.sendActions(for: event)
                    let bytes = try pixels(of: render(view.trackView))
                    let paintedRows = (0..<24).filter { y in
                        (0..<Int(width)).contains { x in bytes[(y * Int(width) + x) * 4 + 3] > 30 }
                    }
                    let top = try XCTUnwrap(paintedRows.first)
                    let bottom = try XCTUnwrap(paintedRows.last)
                    XCTAssertEqual(CGFloat(top + bottom + 1) / 2, view.bounds.midY, accuracy: 0.5)
                    XCTAssertEqual(slider.frame, nativeFrame)
                    XCTAssertEqual(slider.value, 0.5)
                }
            }
        }
    }

    private func render(_ view: UIView, scale: CGFloat = 1) -> UIImage {
        view.contentScaleFactor = scale
        view.layer.displayIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let size = view.superview?.bounds.size ?? view.bounds.size
        return UIGraphicsImageRenderer(size: size, format: format).image {
            $0.cgContext.translateBy(x: view.frame.minX, y: view.frame.minY)
            view.layer.render(in: $0.cgContext)
        }
    }

    private func pixels(of image: UIImage) throws -> [UInt8] {
        let image = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
