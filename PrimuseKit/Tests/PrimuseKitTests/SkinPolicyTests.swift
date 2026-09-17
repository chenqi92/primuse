import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin migration, companions and contrast")
struct SkinPolicyTests {

    // MARK: - 从「极简模式」迁移

    @Test("原来开着极简模式的用户落到极简样式,其余保持经典")
    func legacyMinimalModeMigratesToMinimalSkin() {
        #expect(
            SkinMigrationPolicy.initialSkinID(storedSkinID: nil, legacyNavigationModeRawValue: "minimal")
                == SkinCatalog.minimalID
        )
        #expect(
            SkinMigrationPolicy.initialSkinID(storedSkinID: nil, legacyNavigationModeRawValue: "standard")
                == SkinCatalog.classicID
        )
        #expect(
            SkinMigrationPolicy.initialSkinID(storedSkinID: nil, legacyNavigationModeRawValue: nil)
                == SkinCatalog.classicID
        )
        #expect(
            SkinMigrationPolicy.initialSkinID(storedSkinID: "", legacyNavigationModeRawValue: "future-mode")
                == SkinCatalog.classicID
        )
    }

    @Test("已经选过样式的人不会被旧开关改写")
    func explicitSkinChoiceWinsOverLegacyToggle() {
        #expect(
            SkinMigrationPolicy.initialSkinID(
                storedSkinID: SkinCatalog.classicID,
                legacyNavigationModeRawValue: "minimal"
            ) == SkinCatalog.classicID
        )
    }

    @Test("写回旧开关的值与样式的导航方式一致")
    func legacyToggleMirrorsTheSkin() {
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinCatalog.classic) == "standard")
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinCatalog.minimal) == "minimal")
        #expect(SkinMigrationPolicy.legacyNavigationModeRawValue(for: SkinCatalog.midnight) == "minimal")
    }

    // MARK: - 配套

    @Test("没有样式认领的款式是基础款,始终可用")
    func unclaimedStylesAreAlwaysAvailable() {
        #expect(SkinCompanionPolicy.isAvailable(styleID: "aurora_glass", kind: .lyricPoster))
        #expect(SkinCompanionPolicy.isAvailable(styleID: "starryNight", kind: .immersiveStage))
    }

    @Test("样式可用,它带来的配套才可用")
    func companionsFollowTheirSkin() {
        let locked = SkinDefinition(
            id: "neon",
            nameKey: "k",
            descriptionKey: "k",
            access: .unlockable(unlockID: "skin.neon"),
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            companions: SkinCompanions(
                immersiveStageIDs: ["neonSpectrum"],
                lyricPosterStyleIDs: ["radio_card"],
                preferredLyricPosterStyleID: "radio_card"
            )
        )
        let catalog = SkinCatalog.all + [locked]

        #expect(!SkinCompanionPolicy.isAvailable(styleID: "radio_card", kind: .lyricPoster, catalog: catalog))
        #expect(
            SkinCompanionPolicy.isAvailable(
                styleID: "radio_card",
                kind: .lyricPoster,
                catalog: catalog,
                unlocked: ["skin.neon"]
            )
        )
        // 海报 id 与舞台 id 是两个目录,互不串。
        #expect(SkinCompanionPolicy.isAvailable(styleID: "radio_card", kind: .immersiveStage, catalog: catalog))
        #expect(
            SkinCompanionPolicy.availableStyleIDs(
                from: ["aurora_glass", "radio_card", "deep_sea"],
                kind: .lyricPoster,
                catalog: catalog
            ) == ["aurora_glass", "deep_sea"]
        )
    }

    @Test("极简带来的配套对所有人可用")
    func minimalCompanionsAreAvailableToEveryone() {
        for styleID in SkinCatalog.minimal.companions.lyricPosterStyleIDs {
            #expect(SkinCompanionPolicy.isAvailable(styleID: styleID, kind: .lyricPoster))
        }
        for styleID in SkinCatalog.minimal.companions.immersiveStageIDs {
            #expect(SkinCompanionPolicy.isAvailable(styleID: styleID, kind: .immersiveStage))
        }
    }

    @Test("手选过的款式优先,失效时退回默认,没选过才用样式建议的")
    func companionResolutionOrder() {
        #expect(
            SkinCompanionPolicy.resolvedStyleID(
                kind: .lyricPoster,
                userChoice: nil,
                activeSkin: SkinCatalog.minimal,
                fallbackStyleID: "aurora_glass"
            ) == "deep_sea"
        )
        #expect(
            SkinCompanionPolicy.resolvedStyleID(
                kind: .lyricPoster,
                userChoice: nil,
                activeSkin: SkinCatalog.classic,
                fallbackStyleID: "aurora_glass"
            ) == "aurora_glass"
        )
        #expect(
            SkinCompanionPolicy.resolvedStyleID(
                kind: .lyricPoster,
                userChoice: "vinyl",
                activeSkin: SkinCatalog.minimal,
                fallbackStyleID: "aurora_glass"
            ) == "vinyl"
        )

        let locked = SkinDefinition(
            id: "neon",
            nameKey: "k",
            descriptionKey: "k",
            access: .unlockable(unlockID: "skin.neon"),
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            companions: SkinCompanions(lyricPosterStyleIDs: ["radio_card"])
        )
        #expect(
            SkinCompanionPolicy.resolvedStyleID(
                kind: .lyricPoster,
                userChoice: "radio_card",
                activeSkin: SkinCatalog.classic,
                fallbackStyleID: "aurora_glass",
                catalog: SkinCatalog.all + [locked]
            ) == "aurora_glass"
        )
    }

    @Test("全屏效果:亲手选过或别的设备同步来的选择算数,其余交给样式建议的那一款")
    func immersiveStageFollowsTheSkinUntilTheUserChooses() {
        // 存储键启动时就会被写成默认值,所以「是默认值且没动过手」才算没选过。
        #expect(SkinCompanionPolicy.explicitChoice(storedStyleID: "native", defaultStyleID: "native", userSelected: false) == nil)
        #expect(SkinCompanionPolicy.explicitChoice(storedStyleID: "native", defaultStyleID: "native", userSelected: true) == "native")
        #expect(SkinCompanionPolicy.explicitChoice(storedStyleID: "vinylDeck", defaultStyleID: "native", userSelected: false) == "vinylDeck")

        func effective(stored: String, userSelected: Bool, skin: SkinDefinition) -> String {
            SkinCompanionPolicy.resolvedStyleID(
                kind: .immersiveStage,
                userChoice: SkinCompanionPolicy.explicitChoice(
                    storedStyleID: stored,
                    defaultStyleID: "native",
                    userSelected: userSelected
                ),
                activeSkin: skin,
                fallbackStyleID: "native"
            )
        }
        // 极简带来自己的全屏效果;经典没有建议,保持原生播放页。
        #expect(effective(stored: "native", userSelected: false, skin: SkinCatalog.minimal) == "coverMosaic")
        #expect(effective(stored: "native", userSelected: false, skin: SkinCatalog.classic) == "native")
        // 在极简下亲手选回原生,就一直是原生。
        #expect(effective(stored: "native", userSelected: true, skin: SkinCatalog.minimal) == "native")
        #expect(effective(stored: "vinylDeck", userSelected: false, skin: SkinCatalog.minimal) == "vinylDeck")
        #expect(SkinCatalog.minimal.companions.preferredImmersiveStageID == "coverMosaic")
    }

    @Test("声明了不存在的配套、或建议了自己没带的款式,都不合格")
    func companionDeclarationsAreValidated() {
        let skin = SkinDefinition(
            id: "sloppy",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            companions: SkinCompanions(
                lyricPosterStyleIDs: ["typo_style"],
                preferredLyricPosterStyleID: "someone_elses"
            )
        )
        let issues = SkinValidationPolicy.issues(in: skin, knownLyricPosterStyleIDs: ["aurora_glass"])
        #expect(issues.contains(.unknownCompanion(skinID: "sloppy", kind: .lyricPoster, styleID: "typo_style")))
        #expect(
            issues.contains(
                .preferredCompanionNotIncluded(skinID: "sloppy", kind: .lyricPoster, styleID: "someone_elses")
            )
        )
        // 不给目录就不校验存在性,但「建议的必须是自己带的」始终检查。
        #expect(
            !SkinValidationPolicy.issues(in: skin)
                .contains(.unknownCompanion(skinID: "sloppy", kind: .lyricPoster, styleID: "typo_style"))
        )
    }

    // MARK: - 对比度

    @Test("内置样式在深浅两种底色下文字都读得清")
    func builtInSkinsAreLegible() {
        for skin in SkinCatalog.all + SkinCatalog.lab {
            let findings = SkinContrastPolicy.findings(in: skin)
            #expect(findings.isEmpty, "\(skin.id): \(findings)")
        }
    }

    @Test("看不清的配色会被拦下")
    func illegibleSkinIsRejected() {
        var colors = SkinCatalog.minimal.colors
        colors[.textSecondary] = .fixed(
            light: SkinColorValue(hex: 0x0E1726, opacity: 0.25),
            dark: SkinColorValue(hex: 0xF2F5FA, opacity: 0.20)
        )
        let washedOut = SkinDefinition(
            id: "washed-out",
            nameKey: "k",
            descriptionKey: "k",
            colors: colors,
            metrics: SkinCatalog.minimal.metrics,
            typography: SkinCatalog.minimal.typography,
            motion: SkinCatalog.minimal.motion
        )
        let findings = SkinContrastPolicy.findings(in: washedOut)
        #expect(findings.contains { $0.foreground == .textSecondary && $0.scheme == .dark })
        #expect(findings.contains { $0.foreground == .textSecondary && $0.scheme == .light })
    }

    @Test("相对亮度与对比度按 WCAG 计算")
    func contrastMath() {
        let white = SkinContrastPolicy.RGBA(red: 1, green: 1, blue: 1, alpha: 1)
        let black = SkinContrastPolicy.RGBA(red: 0, green: 0, blue: 0, alpha: 1)
        let ratio = SkinContrastPolicy.contrastRatio(white, black)
        #expect(abs(ratio - 21) < 0.001)
        let half = SkinContrastPolicy.RGBA(red: 1, green: 1, blue: 1, alpha: 0.5).composited(over: black)
        #expect(abs(half.red - 0.5) < 0.0001)
        #expect(half.alpha == 1)
    }

    @Test("经典跟随系统语义色,不在对比度校验范围内")
    func classicIsOutOfScopeForContrast() {
        #expect(SkinContrastPolicy.findings(in: SkinCatalog.classic).isEmpty)
    }
}
