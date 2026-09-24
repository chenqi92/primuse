import Foundation
@testable import PrimuseKit

extension SkinFixtures {
    /// 午夜:只改数据、不碰任何视图的一组 token —— 恒定暗底、冷蓝强调、更大的圆角与更松的间距、
    /// 圆润字形。它曾经列在开发构建的皮肤目录里;只换色不构成一套皮肤,现在只作为测试夹具,
    /// 用来走「待解锁」在选择、回落、权益换算这些看不见的路径。
    static let midnight: SkinDefinition = {
        func ink(_ opacity: Double) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: 0xE8ECF4, opacity: opacity),
                dark: SkinColorValue(hex: 0xE8ECF4, opacity: opacity)
            )
        }
        func solid(_ hex: UInt32, _ opacity: Double = 1) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: hex, opacity: opacity),
                dark: SkinColorValue(hex: hex, opacity: opacity)
            )
        }

        return SkinDefinition(
            id: "midnight",
            nameKey: "skin.midnight.name",
            descriptionKey: "skin.midnight.description",
            appearance: .forcesDark,
            pageBackground: .canvas,
            access: .unlockable(unlockID: "skin.midnight"),
            colors: [
                .textPrimary: ink(1.0),
                .textSecondary: ink(0.62),
                .textTertiary: ink(0.50),
                .textQuaternary: ink(0.26),
                .textOnAccent: solid(0x06101F),
                .textOnScrim: .system(.white),

                .canvas: solid(0x0A0F18),
                .canvasGlow: solid(0x111C30),
                .canvasElevated: solid(0x121926),
                .canvasSunken: solid(0x05080E),
                .scrim: solid(0x05080E, 0.72),

                .surface: ink(0.06),
                .surfaceElevated: ink(0.10),
                .surfacePressed: ink(0.16),
                .chip: ink(0.08),
                .chipSelected: solid(0x5AC8FA, 0.28),

                .separator: ink(0.10),
                .separatorStrong: ink(0.22),
                .surfaceBorder: ink(0.14),
                .focusRing: solid(0x5AC8FA),

                .accent: solid(0x5AC8FA),
                .accentMuted: solid(0x5AC8FA, 0.34),
                .accentSoft: solid(0x5AC8FA, 0.16),

                .success: solid(0x5BD6A0),
                .warning: solid(0xF2B33D),
                .danger: solid(0xFF6B6B),

                .chromeBackground: solid(0x0A0F18, 0.92),
                .chromeBorder: ink(0.08),
                .chromeItem: ink(0.55),
                .chromeItemSelected: solid(0x5AC8FA),
            ],
            metrics: [
                .radiusSmall: 12,
                .radiusMedium: 18,
                .radiusLarge: 26,
                .radiusChip: 999,
                .radiusCard: 22,
                .radiusArtwork: 10,
                .radiusPill: 999,

                .spacingTight: 6,
                .spacingSmall: 10,
                .spacingMedium: 16,
                .spacingLarge: 22,
                .spacingSection: 32,

                .controlHeightSmall: 32,
                .controlHeightMedium: 38,
                .controlHeightLarge: 50,
                .iconSizeSmall: 15,
                .iconSizeMedium: 18,
                .iconSizeLarge: 24,

                .hairline: 0.5,
                .borderWidth: 1,
                .shadowRadius: 18,
                .shadowOpacity: 0.38,

                .chromeTopPadding: 10,
                .chromeBottomPadding: 12,
                .chromeItemSpacing: 10,
                .chromeChipHeight: 38,
                .chromeChipRowHeight: 42,
                .chromeChipSpacing: 10,
                .chromeChipRowSpacing: 14,
                .chromeCollapsedChipHeight: 50,
                .chromeSearchFieldHeight: 50,
                .chromeHorizontalInset: 16,
            ],
            typography: [
                .displayTitle: SkinTypeSpec(size: 32, weight: .heavy, design: .rounded, relativeTo: .largeTitle),
                .pageTitle: SkinTypeSpec(size: 21, weight: .bold, design: .rounded, relativeTo: .title2),
                .sectionTitle: SkinTypeSpec(size: 16, weight: .bold, design: .rounded, relativeTo: .headline),
                .bodyStrong: SkinTypeSpec(size: 15, weight: .semibold, design: .rounded, relativeTo: .body),
                .body: SkinTypeSpec(size: 15, design: .rounded, relativeTo: .body),
                .callout: SkinTypeSpec(size: 14, design: .rounded, relativeTo: .callout),
                .caption: SkinTypeSpec(size: 12, design: .rounded, relativeTo: .caption),
                .meta: SkinTypeSpec(size: 11, design: .rounded, relativeTo: .caption),
                .chrome: SkinTypeSpec(size: 15, weight: .semibold, design: .rounded, relativeTo: .subheadline),
                .chromeCompact: SkinTypeSpec(size: 14.5, weight: .semibold, design: .rounded, relativeTo: .subheadline),
                .chromeField: SkinTypeSpec(size: 16, design: .rounded, relativeTo: .subheadline),
                .numeric: SkinTypeSpec(size: 13, design: .monospaced, relativeTo: .footnote),
                .rowTitle: .textStyle(.subheadline, weight: .semibold, design: .rounded),
                .rowSubtitle: .textStyle(.caption, design: .rounded),
            ],
            motion: [
                .selection: .spring(response: 0.36, dampingFraction: 0.78),
                .chromeCollapse: .spring(response: 0.36, dampingFraction: 0.82),
                .chromeReveal: .smooth(duration: 0.32, extraBounce: 0.1),
                .pageSwitch: .easeOut(duration: 0.22),
                .press: .easeOut(duration: 0.14),
                .sheet: .spring(response: 0.5, dampingFraction: 0.86),
                .contentAppear: .easeOut(duration: 0.28),
                .heroReflow: .easeInOut(duration: 1.6),
                .heroFocus: .spring(response: 0.6, dampingFraction: 0.84),
                .hover: .easeOut(duration: 0.14),
                .control: .easeOut(duration: 0.2),
                .list: .snappy(duration: 0.26, extraBounce: 0.05),
                .panel: .easeInOut(duration: 0.3),
                .trackChange: .easeInOut(duration: 0.34),
                .ambient: .easeInOut(duration: 0.6),
            ],
            // 与极简同一个外壳,表面大多是经典实现 —— 换的只有数据。
            shell: .topTabs,
            surfaces: [
                .player: SkinSurfaceVariant.Player.sheetActions.rawValue,
                .queue: SkinSurfaceVariant.Queue.nowPlayingCard.rawValue,
                .settingsRoot: SkinSurfaceVariant.SettingsRoot.hub.rawValue,
            ]
        )
    }()
}
