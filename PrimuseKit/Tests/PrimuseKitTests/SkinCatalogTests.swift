import Foundation
import Testing
@testable import PrimuseKit

@Suite("Skin catalog and selection")
struct SkinCatalogTests {

    // MARK: - 完整性

    /// 少定义一个 token,运行时表现为「某个控件颜色突然回到兜底值」——
    /// 这种缺陷肉眼走查发现不了,只能靠这条断言拦住。
    @Test("内置样式目录无缺失、无畸形取值")
    func builtInCatalogIsComplete() {
        let issues = SkinValidationPolicy.catalogIssues()
        #expect(issues.isEmpty, "\(issues)")
    }

    @Test("每套样式都覆盖全部 token,外壳成立,每个表面的实现都已登记")
    func everySkinCoversEveryToken() {
        for skin in SkinFixtures.catalogWithUnlockable {
            #expect(skin.colors.count == SkinColorToken.allCases.count)
            #expect(skin.metrics.count == SkinMetricToken.allCases.count)
            #expect(skin.typography.count == SkinTypographyToken.allCases.count)
            #expect(skin.motion.count == SkinMotionToken.allCases.count)
            #expect(skin.shell.isValid, "\(skin.id) 的外壳凑不成一对")
            for surface in SkinSurface.allCases {
                #expect(
                    SkinSurfaceRegistry.builtIn[surface]?.contains(skin.variantID(for: surface)) == true,
                    "\(skin.id) 的 \(surface.rawValue) 表面实现未登记"
                )
            }
        }
        #expect(SkinValidationPolicy.catalogIssues(SkinFixtures.catalogWithUnlockable).isEmpty)
    }

    @Test("缺 token 会被判为不合格")
    func missingTokenIsRejected() {
        var colors = SkinCatalog.classic.colors
        colors.removeValue(forKey: .accent)
        let broken = SkinDefinition(
            id: "broken",
            nameKey: "k",
            descriptionKey: "k",
            colors: colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            shell: .tabBar
        )
        #expect(
            SkinValidationPolicy.issues(in: broken)
                .contains(.missingColor(skinID: "broken", token: .accent))
        )
    }

    @Test("缺动效位同样不合格")
    func missingMotionIsRejected() {
        var motion = SkinCatalog.classic.motion
        motion.removeValue(forKey: .heroReflow)
        let broken = SkinDefinition(
            id: "still",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: motion,
            shell: .tabBar
        )
        #expect(
            SkinValidationPolicy.issues(in: broken)
                .contains(.missingMotion(skinID: "still", token: .heroReflow))
        )
        #expect(!SkinMotionSpec.spring(response: 0, dampingFraction: 0.8).isWellFormed)
        #expect(!SkinMotionSpec.easeOut(duration: -1).isWellFormed)
        #expect(SkinMotionSpec.none.isWellFormed)
    }

    @Test("未登记的表面实现会被判为不合格")
    func unregisteredSurfaceVariantIsRejected() {
        let broken = SkinDefinition(
            id: "broken-surface",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            shell: .tabBar,
            surfaces: [.player: "not-built"]
        )
        #expect(
            SkinValidationPolicy.issues(in: broken) == [
                .unregisteredSurfaceVariant(
                    skinID: "broken-surface",
                    surface: .player,
                    variant: "not-built"
                ),
            ]
        )
    }

    @Test("兜底样式必须随 App 提供,否则没解锁的用户会被锁在无法渲染的状态")
    func fallbackSkinMustBeIncluded() {
        #expect(!SkinCatalog.fallback.access.requiresUnlock)
        let lockedFallback = SkinDefinition(
            id: "locked-default",
            nameKey: "k",
            descriptionKey: "k",
            access: .unlockable(unlockID: "skin.locked-default"),
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            shell: .tabBar
        )
        #expect(
            SkinValidationPolicy.catalogIssues(
                [lockedFallback],
                fallbackID: "locked-default"
            ).contains(.fallbackSkinRequiresUnlock(id: "locked-default"))
        )
    }

    @Test("目录里的样式都随 App 提供,经典与极简都在,只换色的夹具不在")
    func shippingCatalogIsIncluded() {
        #expect(SkinCatalog.all.map(\.id) == [SkinCatalog.classicID, SkinCatalog.minimalID])
        for skin in SkinCatalog.all {
            #expect(skin.access == .included, "\(skin.id) 不该需要解锁")
        }
        #expect(SkinCatalog.skin(id: SkinCatalog.minimalID) == SkinCatalog.minimal)
        for fixture in SkinFixtures.unlockable {
            #expect(SkinCatalog.skin(id: fixture.id) == nil, "\(fixture.id) 只是测试夹具")
        }
    }

    /// 一套皮肤 = 自己的排版结构与交互。和经典只差 token 的一组数据不构成一套皮肤,不能进目录。
    @Test("目录里除经典外的每套样式,外壳或至少一个表面与经典不同")
    func everyCatalogSkinChangesStructure() {
        for skin in SkinCatalog.all where skin.id != SkinCatalog.classicID {
            let changedSurfaces = SkinSurface.allCases.filter {
                skin.variantID(for: $0) != SkinCatalog.classic.variantID(for: $0)
            }
            #expect(
                skin.shell != SkinCatalog.classic.shell || !changedSurfaces.isEmpty,
                "\(skin.id) 只换了 token"
            )
        }
    }

    // MARK: - classic 必须等同于改造前的观感

    /// 这套结构的前提是「装上之后什么都没变」。classic 的色位除下面四个之外
    /// 全部映射到系统语义色,因此与改造前逐像素一致,也保留系统的增强对比度行为。
    @Test("classic 仅这五位不跟随系统语义色或上下文层级")
    func classicLeansOnSystemColors() {
        let nonSystem = SkinColorToken.allCases.filter { token in
            guard let spec = SkinCatalog.classic.colors[token] else { return false }
            switch spec {
            case .system, .hierarchical: return false
            default: return true
            }
        }
        #expect(
            nonSystem.map(\.rawValue).sorted()
                == ["accentMuted", "accentSoft", "chip", "chipSelected", "scrim"]
        )
    }

    /// 极简顶栏的几何与字号改前改后必须一致 —— 这些数值就是从那个视图里搬出来的,
    /// 动了就是改了外观,而这次调整只应改变「值从哪来」。
    @Test("极简顶栏的几何与字号保持原值")
    func classicPreservesMinimalChromeMetrics() {
        let skin = SkinCatalog.classic
        #expect(skin.metric(.chromeChipHeight) == 34)
        #expect(skin.metric(.chromeChipRowHeight) == 37)
        #expect(skin.metric(.chromeChipRowSpacing) == 9)
        #expect(skin.metric(.chromeCollapsedChipHeight) == 44)
        #expect(skin.metric(.chromeSearchFieldHeight) == 44)
        #expect(skin.metric(.chromeItemSpacing) == 8)
        #expect(skin.metric(.chromeChipSpacing) == 7)
        #expect(skin.metric(.chromeHorizontalInset) == 12)
        #expect(skin.metric(.chromeTopPadding) == 6)
        #expect(skin.metric(.chromeBottomPadding) == 8)
        #expect(skin.metric(.controlHeightLarge) == 44)

        #expect(skin.type(.chrome)?.size == 14.5)
        #expect(skin.type(.chrome)?.weight == .regular)
        #expect(skin.type(.chromeCompact)?.size == 14)
        #expect(skin.type(.chromeCompact)?.weight == .semibold)
        #expect(skin.type(.chromeField)?.size == 15.5)

        #expect(skin.colors[.accentSoft] == .tinted(opacity: 0.14))
        #expect(skin.colors[.chipSelected] == .tinted(opacity: 0.16))
        #expect(skin.colors[.chip] == .systemOpacity(.secondaryLabel, opacity: 0.10))
    }

    /// 列表行原来写的是 `.subheadline` / `.caption`。换成按字号造的字体,行高会差一两个点,
    /// 几千行的列表整体就变了样 —— 所以经典必须仍然解析成系统文本样式。
    @Test("经典的列表行字体仍是系统文本样式")
    func classicRowsKeepSystemTextStyles() {
        let title = SkinCatalog.classic.type(.rowTitle)
        #expect(title == .textStyle(.subheadline))
        #expect(title?.followsTextStyle == true)
        #expect(title?.weight == .regular)
        #expect(SkinCatalog.classic.type(.rowSubtitle) == .textStyle(.caption))
        // 极简只把标题加重半级,行高仍由系统文本样式决定。
        #expect(SkinCatalog.minimal.type(.rowTitle)?.followsTextStyle == true)
        #expect(SkinCatalog.minimal.type(.rowTitle)?.weight == .medium)
        // headline 自带 semibold,不给字重时不能被压成 regular。
        #expect(SkinTypeSpec.textStyle(.headline).weight == .semibold)
        #expect(SkinTypeSpec.textStyle(.headline, weight: .bold).weight == .bold)
        #expect(SkinTypeSpec.textStyle(.body).size == 17)
    }

    @Test("控件高度与图标随字号缩放;圆角、描边、阴影、间距不随")
    func onlySizesScale() {
        for token in [SkinMetricToken.radiusCard, .radiusArtwork, .radiusPill, .hairline, .borderWidth,
                      .shadowRadius, .shadowOpacity, .spacingMedium, .chromeHorizontalInset,
                      .chromeChipRowSpacing, .chromeTopPadding] {
            #expect(!token.scalesWithDynamicType, "\(token.rawValue) 不该随字号缩放")
        }
        for token in [SkinMetricToken.chromeChipHeight, .chromeChipRowHeight, .chromeSearchFieldHeight,
                      .controlHeightLarge, .iconSizeMedium] {
            #expect(token.scalesWithDynamicType, "\(token.rawValue) 应随字号缩放")
        }
        #expect(SkinMetricToken.shadowOpacity.isUnitInterval)
        #expect(!SkinMetricToken.radiusCard.isUnitInterval)
    }

    /// 顶栏折叠的滞回带宽 = 分类行高 + 它上方的间距。行高随字号缩放、间距不缩放,
    /// 与折叠判定那一侧(`MinimalNavigationChromeMetrics`)的算法必须是同一种。
    @Test("经典顶栏让出的高度与折叠判定用的数值同源")
    func classicChromeMatchesCollapseMetrics() {
        let skin = SkinCatalog.classic
        #expect(skin.metric(.chromeChipRowHeight) == Double(MinimalNavigationChromeMetrics.categoryRowHeight))
        #expect(skin.metric(.chromeChipRowSpacing) == Double(MinimalNavigationChromeMetrics.categoryRowTopPadding))
        #expect(SkinMetricToken.chromeChipRowHeight.scalesWithDynamicType)
        #expect(!SkinMetricToken.chromeChipRowSpacing.scalesWithDynamicType)
    }

    @Test("样式之间确有差异,否则换样式只是摆设")
    func skinsDifferSubstantially() {
        for other in [SkinCatalog.minimal, SkinFixtures.midnight] {
            let differingColors = SkinColorToken.allCases.filter {
                SkinCatalog.classic.colors[$0] != other.colors[$0]
            }
            #expect(differingColors.count >= 20, "\(other.id) 与经典只差 \(differingColors.count) 个色位")
        }
        let differingMetrics = SkinMetricToken.allCases.filter {
            SkinCatalog.classic.metrics[$0] != SkinFixtures.midnight.metrics[$0]
        }
        #expect(differingMetrics.count >= 20)
        #expect(SkinFixtures.midnight.appearance == .forcesDark)
        // 极简跟随系统深浅色:「外观」设置在这套样式下必须继续有效。
        #expect(SkinCatalog.minimal.appearance == .adaptive)
        #expect(SkinCatalog.minimal.pageBackground == .canvas)
        #expect(SkinCatalog.classic.pageBackground == .system)
    }

    /// 光脊夹具只有配色:锁定深色、待解锁、不认领任何配套。最后一条是硬约束 ——
    /// 待解锁的皮肤一旦认领基础全屏效果或海报,没解锁的人就再也看不到那一款。
    @Test("光脊夹具是一套完整、读得清、不认领配套的深色配色")
    func nocturneIsADarkPaletteOnly() {
        let skin = SkinFixtures.nocturne
        #expect(SkinValidationPolicy.catalogIssues([SkinCatalog.classic, skin]).isEmpty)
        let findings = SkinContrastPolicy.findings(in: skin)
        #expect(findings.isEmpty, "\(findings)")
        #expect(skin.access == .unlockable(unlockID: "skin.nocturne"))
        #expect(skin.appearance == .forcesDark)
        #expect(skin.pageBackground == .canvas)
        #expect(skin.companions == SkinCompanions.none)
        #expect(skin.companions.isEmpty)
        // 强调色仍跟着主题色设置走,「跟随封面取色」这条链路不断。
        #expect(skin.colors[.accent] == .system(.tint))
        // 只换色,不进目录。
        #expect(SkinCatalog.skin(id: "nocturne") == nil)
    }

    @Test("极简的强调色跟随主题色设置,不切断封面取色")
    func minimalKeepsTheUserAccent() {
        #expect(SkinCatalog.minimal.colors[.accent] == .system(.tint))
        #expect(SkinCatalog.minimal.colors[.chromeItemSelected] == .system(.tint))
        if case .tinted = SkinCatalog.minimal.colors[.accentSoft] {} else {
            Issue.record("accentSoft 应当由强调色派生")
        }
    }

    @Test("极简选用的表面实现与组件样式")
    func minimalSurfaceChoices() {
        let skin = SkinCatalog.minimal
        #expect(skin.home == .poster)
        #expect(skin.libraryRoot == .tiles)
        #expect(skin.songList == .playHeader)
        #expect(skin.collectionDetail == .classic)
        #expect(skin.player == .sheetActions)
        #expect(skin.queue == .nowPlayingCard)
        #expect(skin.search == .browse)
        #expect(skin.radio == .onAir)
        #expect(skin.settingsRoot == .hub)
        #expect(skin.components.card == .tile)
        // 每个表面都显式写在定义里,不靠「没写就是经典」。
        #expect(Set(skin.surfaces.keys) == Set(SkinSurface.allCases))
    }

    @Test("经典的每个表面都是经典实现,外壳、表面与特征位都显式写在定义里")
    func classicSurfaceChoicesAreExplicit() {
        let classic = SkinCatalog.classic
        for surface in SkinSurface.allCases {
            #expect(classic.surfaces[surface] == SkinSurfaceRegistry.classicVariant, "\(surface)")
        }
        #expect(classic.home == .classic)
        #expect(classic.libraryRoot == .classic)
        #expect(classic.songList == .classic)
        #expect(classic.collectionDetail == .classic)
        #expect(classic.player == .classic)
        #expect(classic.queue == .classic)
        #expect(classic.search == .classic)
        #expect(classic.radio == .classic)
        #expect(classic.settingsRoot == .classic)
        #expect(classic.components == .classic)
        #expect(classic.shell == .tabBar)
        // 经典的详情页染封面色,浮层是玻璃。
        #expect(classic.traits.collectionBackdrop == .artworkTint)
        #expect(classic.traits.chromeMaterial == .glass)
    }

    @Test("读不出来或没写的表面取值落到经典实现")
    func unknownSurfaceVariantReadsAsClassic() {
        let skin = SkinDefinition(
            id: "future",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            shell: .topTabs,
            surfaces: [.player: "from-a-future-build", .home: SkinSurfaceVariant.Home.poster.rawValue]
        )
        #expect(skin.player == .classic)
        #expect(skin.home == .poster)
        // 没写的表面。
        #expect(skin.queue == .classic)
        #expect(skin.variantID(for: .search) == SkinSurfaceRegistry.classicVariant)
        #expect(skin.implementation(SkinSurfaceVariant.SettingsRoot.self) == .classic)
    }

    @Test("登记表由实现枚举推导,每个表面都有经典实现")
    func registryIsDerivedFromVariantEnums() {
        for surface in SkinSurface.allCases {
            #expect(
                SkinSurfaceRegistry.builtIn[surface]?.contains(SkinSurfaceRegistry.classicVariant) == true,
                "\(surface)"
            )
            #expect(SkinSurfaceRegistry.variants(of: surface).first == SkinSurfaceRegistry.classicVariant)
        }
        #expect(SkinSurfaceRegistry.builtIn[.home] == ["classic", "poster"])
        #expect(SkinSurfaceRegistry.builtIn[.libraryRoot] == ["classic", "tiles"])
        #expect(SkinSurfaceRegistry.builtIn[.songList] == ["classic", "playHeader"])
        #expect(SkinSurfaceRegistry.builtIn[.collectionDetail] == ["classic"])
        #expect(SkinSurfaceRegistry.builtIn[.player] == ["classic", "sheetActions"])
        #expect(SkinSurfaceRegistry.builtIn[.queue] == ["classic", "nowPlayingCard"])
        #expect(SkinSurfaceRegistry.builtIn[.search] == ["classic", "browse"])
        #expect(SkinSurfaceRegistry.builtIn[.radio] == ["classic", "onAir"])
        #expect(SkinSurfaceRegistry.builtIn[.settingsRoot] == ["classic", "hub"])
        // 每个实现枚举报的表面与登记表里的位置一致。
        #expect(SkinSurfaceVariant.Home.surface == .home)
        #expect(SkinSurfaceVariant.LibraryRoot.surface == .libraryRoot)
        #expect(SkinSurfaceVariant.SongList.surface == .songList)
        #expect(SkinSurfaceVariant.CollectionDetail.surface == .collectionDetail)
        #expect(SkinSurfaceVariant.Player.surface == .player)
        #expect(SkinSurfaceVariant.Queue.surface == .queue)
        #expect(SkinSurfaceVariant.Search.surface == .search)
        #expect(SkinSurfaceVariant.Radio.surface == .radio)
        #expect(SkinSurfaceVariant.SettingsRoot.surface == .settingsRoot)
    }

    @Test("经典的动效取自视图里原有的曲线")
    func classicPreservesExistingCurves() {
        let motion = SkinCatalog.classic.motion
        #expect(motion[.chromeCollapse] == .spring(response: 0.3, dampingFraction: 0.86))
        #expect(motion[.chromeReveal] == .smooth(duration: 0.26, extraBounce: 0))
        #expect(motion[.pageSwitch] == .easeOut(duration: 0.18))
        #expect(motion[.sheet] == .spring(response: 0.45, dampingFraction: 0.92))
        // 全 App 共用的六档与 App 层 `PMMotion` 里的字面量一致。
        #expect(motion[.hover] == .easeOut(duration: 0.12))
        #expect(motion[.control] == .easeOut(duration: 0.18))
        #expect(motion[.list] == .snappy(duration: 0.22, extraBounce: 0))
        #expect(motion[.panel] == .easeInOut(duration: 0.25))
        #expect(motion[.trackChange] == .easeInOut(duration: 0.28))
        #expect(motion[.ambient] == .easeInOut(duration: 0.5))
        #expect(SkinMotionSpec.snappy(duration: 0.22, extraBounce: 0).isWellFormed)
        #expect(!SkinMotionSpec.snappy(duration: 0, extraBounce: 0).isWellFormed)
    }

    // MARK: - 解锁与回落

    @Test("待解锁的样式未解锁时不生效")
    func lockedSkinDoesNotApply() {
        let catalog = SkinFixtures.catalogWithUnlockable
        let unlockID = "skin.midnight"
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.classic, unlocked: []) == .included)
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.minimal, unlocked: []) == .included)
        #expect(SkinSelectionPolicy.availability(of: SkinFixtures.midnight, unlocked: []) == .locked)
        #expect(
            SkinSelectionPolicy.availability(of: SkinFixtures.midnight, unlocked: [unlockID]) == .unlocked
        )
        #expect(SkinSelectionPolicy.effectiveSkinID(requested: "midnight", catalog: catalog) == "classic")
        #expect(
            SkinSelectionPolicy.effectiveSkinID(
                requested: "midnight",
                catalog: catalog,
                unlocked: [unlockID]
            ) == "midnight"
        )
        // 样式 id 本身不是解锁凭据。
        #expect(
            SkinSelectionPolicy.effectiveSkinID(
                requested: "midnight",
                catalog: catalog,
                unlocked: ["midnight"]
            ) == "classic"
        )
    }

    /// 这些路径都发生在看不见的地方:样式被下架、权益失效、
    /// 换设备后同步来一个本机没有的样式 id。打开 App 用肉眼验证不了。
    @Test("异常来源的样式选择一律回落")
    func unknownOrRevokedSkinFallsBack() {
        let catalog = SkinFixtures.catalogWithUnlockable
        #expect(SkinSelectionPolicy.effectiveSkinID(requested: nil) == "classic")
        #expect(
            SkinSelectionPolicy.effectiveSkinID(
                requested: "from-a-future-build",
                unlocked: ["from-a-future-build"]
            ) == "classic"
        )
        // 目录里没有的样式(夹具、别的构建里的皮肤)同步过来也只会回落。
        #expect(SkinSelectionPolicy.effectiveSkinID(requested: "midnight", unlocked: ["skin.midnight"]) == "classic")
        #expect(SkinSelectionPolicy.requiresFallback(current: "midnight", catalog: catalog, unlocked: []))
        #expect(
            !SkinSelectionPolicy.requiresFallback(
                current: "midnight",
                catalog: catalog,
                unlocked: ["skin.midnight"]
            )
        )
        #expect(!SkinSelectionPolicy.requiresFallback(current: "classic", unlocked: []))
        #expect(!SkinSelectionPolicy.requiresFallback(current: "minimal", unlocked: []))
    }

    @Test("样式定义可 JSON 往返,为将来下发样式留口子")
    func skinDefinitionRoundTripsThroughJSON() throws {
        for skin in SkinFixtures.catalogWithUnlockable {
            let data = try JSONEncoder().encode(skin)
            let decoded = try JSONDecoder().decode(SkinDefinition.self, from: data)
            #expect(decoded == skin)
        }
    }
}
