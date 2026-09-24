import Foundation

extension SkinCatalog {
    /// 光脊:近黑的底、顶部一道紫色的光脊、紫灰的墨色层级,桃橙只留给需要人停一下的那一处。
    ///
    /// 六个基色来自 2026 年八月那版同名主题:底色、抬起面、墨色、次级墨色、紫、桃橙。这一步
    /// 只做配色 —— 几何、字体、动效与插槽都沿用极简,唱片目录那套版面(色条长列表、封面光源)
    /// 另做,所以描述里也只承诺一套深色配色。
    ///
    /// 只在深色下成立,因此 `forcesDark`,深浅两档填同一套值。
    public static let nocturne: SkinDefinition = {
        // 墨色 #F3F4FE,次级墨色 #918FA3 —— 后者偏紫,让层级也带上这套配色的色相。
        func ink(_ opacity: Double) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: 0xF3F4FE, opacity: opacity),
                dark: SkinColorValue(hex: 0xF3F4FE, opacity: opacity)
            )
        }
        func muted(_ opacity: Double) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: 0x918FA3, opacity: opacity),
                dark: SkinColorValue(hex: 0x918FA3, opacity: opacity)
            )
        }
        func solid(_ hex: UInt32, _ opacity: Double = 1) -> SkinColorSpec {
            .fixed(
                light: SkinColorValue(hex: hex, opacity: opacity),
                dark: SkinColorValue(hex: hex, opacity: opacity)
            )
        }

        // 封面圆角收小:唱片目录看的是一排方方正正的封套,不是圆角磁贴。其余几何、字体、
        // 动效直接取极简的那三张表 —— 这一步要换的只有颜色。
        var metrics = SkinCatalog.minimal.metrics
        metrics[.radiusArtwork] = 3
        metrics[.radiusCard] = 10

        return SkinDefinition(
            id: "nocturne",
            nameKey: "skin.nocturne.name",
            descriptionKey: "skin.nocturne.description",
            appearance: .forcesDark,
            pageBackground: .canvas,
            access: .unlockable(unlockID: "skin.nocturne"),
            colors: [
                .textPrimary: ink(1.0),
                .textSecondary: muted(1.0),
                .textTertiary: muted(0.72),
                .textQuaternary: ink(0.24),
                // 强调色跟着主题色走,压在它上面的字不能假定底色是浅还是深,取白最稳。
                .textOnAccent: .system(.white),
                .textOnScrim: .system(.white),

                .canvas: solid(0x06070B),
                // 光脊本身:紫压进近黑里的那一道,页面底色由它向 canvas 收。
                .canvasGlow: solid(0x1B1740),
                .canvasElevated: solid(0x0C0D13),
                .canvasSunken: solid(0x030409),
                .scrim: solid(0x03040A, 0.74),

                .surface: ink(0.05),
                .surfaceElevated: ink(0.09),
                .surfacePressed: ink(0.15),
                .chip: ink(0.07),
                .chipSelected: .tinted(opacity: 0.24),

                .separator: ink(0.09),
                .separatorStrong: ink(0.20),
                .surfaceBorder: ink(0.12),
                // 紫在这里是固定的:焦点环不是强调色,它要在任何主题色下都认得出来。
                .focusRing: solid(0xB5A8FC),

                // 强调色不写死。这套皮肤的立意就是「封面是光源」,把 accent 钉成紫色会切断
                // 「跟随封面取色」这条链路,紫因此只出现在光脊与焦点环上。
                .accent: .system(.tint),
                .accentMuted: .tinted(opacity: 0.34),
                .accentSoft: .tinted(opacity: 0.18),

                .success: solid(0x8CCCBD),
                // 桃橙的点睛位:整套配色里唯一的暖色,只用在需要人停一下的地方。
                .warning: solid(0xFA8C63),
                .danger: solid(0xFF6B6B),

                .chromeBackground: solid(0x14112E, 0.88),
                .chromeBorder: ink(0.09),
                .chromeItem: muted(1.0),
                .chromeItemSelected: .system(.tint),
            ],
            metrics: metrics,
            typography: SkinCatalog.minimal.typography,
            motion: SkinCatalog.minimal.motion,
            // 与极简同一组结构实现 —— 这一步换的只有数据。
            slots: [
                .navigationHeader: SkinSlotVariant.NavigationHeader.topTabs.rawValue,
                .bottomChrome: SkinSlotVariant.BottomChrome.dockedBar.rawValue,
                .detailHeader: SkinSlotVariant.DetailHeader.coverWall.rawValue,
                .settingsRoot: SkinSlotVariant.SettingsRoot.hub.rawValue,
                .homeLayout: SkinSlotVariant.HomeLayout.classic.rawValue,
                .listRow: SkinSlotVariant.ListRow.classic.rawValue,
                .card: SkinSlotVariant.Card.classic.rawValue,
                .playerStage: SkinSlotVariant.PlayerStage.sheetActions.rawValue,
            ]
            // 配套留空,而且不能填现有的基础款。被皮肤认领的款式只在认领它的皮肤可用时才出现,
            // 一套待解锁的皮肤认领了基础全屏效果或海报,所有没解锁的人就再也看不到那一款。
            // 这套皮肤自己的效果与海报做出来之后,才在这里登记它们。
        )
    }()
}
