import Foundation

extension SkinCatalog {
    /// 极简:深海蓝底、封面墙头图、悬浮胶囊播放条。界面自己几乎没有颜色,
    /// 颜色全部来自封面与用户的主题色。
    ///
    /// 跟随系统深浅色 —— 「外观」设置在这套样式下依然有效,浅色是同一套版式换色表。
    public static let minimal: SkinDefinition = {
        // 深色以 #F2F5FA 为墨,浅色以 #0E1726 为墨,各层级只是同一种墨的不同浓度。
        func ink(_ darkOpacity: Double, _ lightOpacity: Double) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: 0x0E1726, opacity: lightOpacity),
                dark: SkinColorValue(hex: 0xF2F5FA, opacity: darkOpacity)
            )
        }
        // 深色叠白、浅色叠墨的半透明面。
        func veil(_ darkOpacity: Double, _ lightOpacity: Double) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: 0x0E1726, opacity: lightOpacity),
                dark: SkinColorValue(hex: 0xFFFFFF, opacity: darkOpacity)
            )
        }
        func solid(light: UInt32, dark: UInt32) -> SkinColorSpec {
            .fixed(light: SkinColorValue(hex: light), dark: SkinColorValue(hex: dark))
        }

        return SkinDefinition(
            id: minimalID,
            nameKey: "skin.minimal.name",
            descriptionKey: "skin.minimal.description",
            appearance: .adaptive,
            pageBackground: .canvas,
            access: .included,
            colors: [
                .textPrimary: ink(1.0, 1.0),
                .textSecondary: ink(0.62, 0.62),
                // 第三级常压在 11–13pt 的小字上(时长、计数、格式),对比度不能只按装饰元素来定。
                .textTertiary: ink(0.50, 0.56),
                .textQuaternary: ink(0.26, 0.28),
                .textOnAccent: .system(.white),
                .textOnScrim: .system(.white),

                .canvas: solid(light: 0xF3F5F9, dark: 0x0B1422),
                .canvasGlow: solid(light: 0xE4EBF5, dark: 0x13223A),
                .canvasElevated: solid(light: 0xFFFFFF, dark: 0x101B2D),
                .canvasSunken: solid(light: 0xE9EDF3, dark: 0x080E18),
                .scrim: .fixed(
                    light: SkinColorValue(hex: 0x0E1726, opacity: 0.35),
                    dark: SkinColorValue(hex: 0x060A12, opacity: 0.72)
                ),

                .surface: veil(0.06, 0.05),
                .surfaceElevated: veil(0.10, 0.08),
                .surfacePressed: veil(0.16, 0.12),
                .chip: veil(0.06, 0.05),
                .chipSelected: .tinted(opacity: 0.20),

                .separator: veil(0.07, 0.07),
                .separatorStrong: veil(0.14, 0.14),
                .surfaceBorder: veil(0.08, 0.08),
                .focusRing: .system(.tint),

                // 强调色不写死:它跟着用户的主题色设置走,「跟随封面取色」这条链路不断。
                .accent: .system(.tint),
                .accentMuted: .tinted(opacity: 0.34),
                .accentSoft: .tinted(opacity: 0.18),

                .success: solid(light: 0x1E9E6A, dark: 0x5BD6A0),
                .warning: solid(light: 0xB87A10, dark: 0xF2B33D),
                .danger: solid(light: 0xD93A3A, dark: 0xFF6B6B),

                .chromeBackground: .fixed(
                    light: SkinColorValue(hex: 0xFFFFFF, opacity: 0.86),
                    dark: SkinColorValue(hex: 0x1B283C, opacity: 0.82)
                ),
                .chromeBorder: veil(0.10, 0.08),
                .chromeItem: ink(0.62, 0.62),
                .chromeItemSelected: .system(.tint),
            ],
            metrics: [
                .radiusSmall: 8,
                .radiusMedium: 14,
                .radiusLarge: 22,
                .radiusChip: 999,
                .radiusCard: 16,
                .radiusArtwork: 8,
                .radiusPill: 999,

                .spacingTight: 4,
                .spacingSmall: 8,
                .spacingMedium: 12,
                .spacingLarge: 16,
                .spacingSection: 22,

                .controlHeightSmall: 30,
                .controlHeightMedium: 36,
                .controlHeightLarge: 44,
                .iconSizeSmall: 15,
                .iconSizeMedium: 18,
                .iconSizeLarge: 22,

                .hairline: 0.5,
                .borderWidth: 1,
                .shadowRadius: 16,
                .shadowOpacity: 0.30,

                // 顶栏沿用现有几何:用户已经熟悉这条栏的手感,换的是材质不是尺寸。
                .chromeTopPadding: 6,
                .chromeBottomPadding: 8,
                .chromeItemSpacing: 8,
                .chromeChipHeight: 34,
                .chromeChipRowHeight: 37,
                .chromeChipSpacing: 7,
                .chromeChipRowSpacing: 9,
                .chromeCollapsedChipHeight: 44,
                .chromeSearchFieldHeight: 44,
                .chromeHorizontalInset: 12,
            ],
            typography: [
                .displayTitle: SkinTypeSpec(size: 30, weight: .bold, relativeTo: .largeTitle),
                .pageTitle: SkinTypeSpec(size: 24, weight: .bold, relativeTo: .title2),
                .sectionTitle: SkinTypeSpec(size: 18, weight: .bold, relativeTo: .headline),
                .bodyStrong: SkinTypeSpec(size: 15, weight: .semibold, relativeTo: .body),
                .body: SkinTypeSpec(size: 15, weight: .medium, relativeTo: .body),
                .callout: SkinTypeSpec(size: 14.5, relativeTo: .callout),
                .caption: SkinTypeSpec(size: 12.5, relativeTo: .caption),
                .meta: SkinTypeSpec(size: 11.5, relativeTo: .caption),
                .chrome: SkinTypeSpec(size: 14.5, weight: .regular, relativeTo: .subheadline),
                .chromeCompact: SkinTypeSpec(size: 14, weight: .semibold, relativeTo: .subheadline),
                .chromeField: SkinTypeSpec(size: 15.5, relativeTo: .subheadline),
                .numeric: SkinTypeSpec(size: 12, design: .monospaced, relativeTo: .footnote),
                // 行高交给系统文本样式,只把标题加重半级。
                .rowTitle: .textStyle(.subheadline, weight: .medium),
                .rowSubtitle: .textStyle(.caption),
            ],
            motion: [
                .selection: .spring(response: 0.3, dampingFraction: 0.86),
                .chromeCollapse: .spring(response: 0.3, dampingFraction: 0.86),
                .chromeReveal: .smooth(duration: 0.26, extraBounce: 0),
                .pageSwitch: .easeOut(duration: 0.18),
                .press: .easeOut(duration: 0.12),
                .sheet: .spring(response: 0.45, dampingFraction: 0.92),
                .contentAppear: .easeOut(duration: 0.22),
                .heroReflow: .easeInOut(duration: 1.4),
                .heroFocus: .spring(response: 0.55, dampingFraction: 0.9),
            ],
            slots: [
                .navigationHeader: SkinSlotVariant.NavigationHeader.minimal.rawValue,
                .bottomChrome: SkinSlotVariant.BottomChrome.floatingCapsule.rawValue,
                .detailHeader: SkinSlotVariant.DetailHeader.coverWall.rawValue,
                .settingsRoot: SkinSlotVariant.SettingsRoot.hub.rawValue,
                .homeLayout: SkinSlotVariant.HomeLayout.classic.rawValue,
                .listRow: SkinSlotVariant.ListRow.classic.rawValue,
                .card: SkinSlotVariant.Card.classic.rawValue,
                .playerStage: SkinSlotVariant.PlayerStage.classic.rawValue,
            ],
            companions: SkinCompanions(
                immersiveStageIDs: ["coverGallery"],
                lyricPosterStyleIDs: ["deep_sea"],
                preferredLyricPosterStyleID: "deep_sea"
            )
        )
    }()
}
