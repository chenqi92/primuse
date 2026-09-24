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

    @Test("每套样式都覆盖全部 token,且插槽已登记")
    func everySkinCoversEveryToken() {
        for skin in SkinCatalog.all + SkinCatalog.lab {
            #expect(skin.colors.count == SkinColorToken.allCases.count)
            #expect(skin.metrics.count == SkinMetricToken.allCases.count)
            #expect(skin.typography.count == SkinTypographyToken.allCases.count)
            #expect(skin.motion.count == SkinMotionToken.allCases.count)
            for slot in SkinSlot.allCases {
                #expect(
                    SkinSlotRegistry.builtIn[slot]?.contains(skin.variant(for: slot)) == true,
                    "\(skin.id) 的 \(slot.rawValue) 插槽未登记"
                )
            }
        }
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
            motion: SkinCatalog.classic.motion
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
            motion: motion
        )
        #expect(
            SkinValidationPolicy.issues(in: broken)
                .contains(.missingMotion(skinID: "still", token: .heroReflow))
        )
        #expect(!SkinMotionSpec.spring(response: 0, dampingFraction: 0.8).isWellFormed)
        #expect(!SkinMotionSpec.easeOut(duration: -1).isWellFormed)
        #expect(SkinMotionSpec.none.isWellFormed)
    }

    @Test("未登记的插槽实现会被判为不合格")
    func unregisteredSlotVariantIsRejected() {
        var slots = SkinSlotRegistry.allClassic
        slots[.playerStage] = "not-built"
        let broken = SkinDefinition(
            id: "broken-slot",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            slots: slots
        )
        #expect(
            SkinValidationPolicy.issues(in: broken)
                .contains(
                    .unregisteredSlotVariant(
                        skinID: "broken-slot",
                        slot: .playerStage,
                        variant: "not-built"
                    )
                )
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
            motion: SkinCatalog.classic.motion
        )
        #expect(
            SkinValidationPolicy.catalogIssues(
                [lockedFallback],
                fallbackID: "locked-default"
            ).contains(.fallbackSkinRequiresUnlock(id: "locked-default"))
        )
    }

    @Test("正式目录里的样式都随 App 提供,经典与极简都在")
    func shippingCatalogIsIncluded() {
        #expect(SkinCatalog.all.map(\.id) == [SkinCatalog.classicID, SkinCatalog.minimalID])
        for skin in SkinCatalog.all {
            #expect(skin.access == .included, "\(skin.id) 不该需要解锁")
        }
        // 打磨中的样式不进正式目录,按 id 默认也查不到。
        #expect(SkinCatalog.skin(id: "midnight") == nil)
        #expect(SkinCatalog.skin(id: "midnight", includingLab: true) != nil)
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
        for other in [SkinCatalog.minimal, SkinCatalog.midnight] {
            let differingColors = SkinColorToken.allCases.filter {
                SkinCatalog.classic.colors[$0] != other.colors[$0]
            }
            #expect(differingColors.count >= 20, "\(other.id) 与经典只差 \(differingColors.count) 个色位")
        }
        let differingMetrics = SkinMetricToken.allCases.filter {
            SkinCatalog.classic.metrics[$0] != SkinCatalog.midnight.metrics[$0]
        }
        #expect(differingMetrics.count >= 20)
        #expect(SkinCatalog.midnight.appearance == .forcesDark)
        // 极简跟随系统深浅色:「外观」设置在这套样式下必须继续有效。
        #expect(SkinCatalog.minimal.appearance == .adaptive)
        #expect(SkinCatalog.minimal.pageBackground == .canvas)
        #expect(SkinCatalog.classic.pageBackground == .system)
    }

    /// 光脊这一步只有配色:锁定深色、待解锁、不认领任何配套。最后一条是硬约束 ——
    /// 待解锁的皮肤一旦认领基础全屏效果或海报,没解锁的人就再也看不到那一款。
    @Test("光脊是一套完整、读得清、不认领配套的深色配色")
    func nocturneIsADarkPaletteOnly() {
        let skin = SkinCatalog.nocturne
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
        // 打磨中的样式只在开发构建里出现。
        #expect(SkinCatalog.skin(id: "nocturne") == nil)
        #expect(SkinCatalog.skin(id: "nocturne", includingLab: true) != nil)
    }

    @Test("极简的强调色跟随主题色设置,不切断封面取色")
    func minimalKeepsTheUserAccent() {
        #expect(SkinCatalog.minimal.colors[.accent] == .system(.tint))
        #expect(SkinCatalog.minimal.colors[.chromeItemSelected] == .system(.tint))
        if case .tinted = SkinCatalog.minimal.colors[.accentSoft] {} else {
            Issue.record("accentSoft 应当由强调色派生")
        }
    }

    @Test("极简选用的结构实现")
    func minimalSlotChoices() {
        let skin = SkinCatalog.minimal
        #expect(skin.navigationHeader == .minimal)
        #expect(skin.bottomChrome == .floatingCapsule)
        #expect(skin.detailHeader == .coverWall)
        #expect(skin.settingsRoot == .hub)
        #expect(skin.playerStage == .sheetActions)
        #expect(skin.homeLayout == .poster)
        #expect(skin.card == .tile)
        #expect(skin.listRow == .playHeader)
    }

    @Test("经典的每个插槽都是经典实现,插槽与特征位都显式写在定义里")
    func classicSlotChoicesAreExplicit() {
        let classic = SkinCatalog.classic
        for slot in SkinSlot.allCases {
            #expect(classic.slots[slot] == SkinSlotRegistry.classicVariant, "\(slot)")
        }
        #expect(classic.playerStage == .classic)
        #expect(classic.navigationHeader == .classic)
        #expect(classic.bottomChrome == .classic)
        #expect(classic.detailHeader == .classic)
        #expect(classic.settingsRoot == .classic)
        #expect(classic.homeLayout == .classic)
        #expect(classic.card == .classic)
        #expect(classic.listRow == .classic)
        // 经典的详情页染封面色,浮层是玻璃。
        #expect(classic.traits.collectionBackdrop == .artworkTint)
        #expect(classic.traits.chromeMaterial == .glass)
    }

    @Test("每个插槽登记的实现里都有经典实现")
    func everySlotRegistersClassic() {
        for slot in SkinSlot.allCases {
            #expect(SkinSlotRegistry.builtIn[slot]?.contains(SkinSlotRegistry.classicVariant) == true, "\(slot)")
        }
        #expect(SkinSlotRegistry.variants(of: .homeLayout).contains(SkinSlotVariant.HomeLayout.poster.rawValue))
        #expect(SkinSlotRegistry.variants(of: .card).contains(SkinSlotVariant.Card.tile.rawValue))
        #expect(SkinSlotRegistry.variants(of: .listRow).contains(SkinSlotVariant.ListRow.playHeader.rawValue))
    }

    @Test("读不出来的插槽取值落到经典实现")
    func unknownSlotVariantReadsAsClassic() {
        var slots = SkinSlotRegistry.allClassic
        slots[.bottomChrome] = "from-a-future-build"
        let skin = SkinDefinition(
            id: "future",
            nameKey: "k",
            descriptionKey: "k",
            colors: SkinCatalog.classic.colors,
            metrics: SkinCatalog.classic.metrics,
            typography: SkinCatalog.classic.typography,
            motion: SkinCatalog.classic.motion,
            slots: slots
        )
        #expect(skin.bottomChrome == .classic)
    }

    @Test("登记表由实现枚举推导,每个插槽至少有经典实现")
    func registryIsDerivedFromVariantEnums() {
        for slot in SkinSlot.allCases {
            #expect(SkinSlotRegistry.builtIn[slot]?.contains(SkinSlotRegistry.classicVariant) == true)
        }
        #expect(SkinSlotRegistry.builtIn[.navigationHeader] == ["classic", "minimal"])
        #expect(SkinSlotRegistry.builtIn[.detailHeader] == ["classic", "coverWall"])
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
        let catalog = SkinCatalog.all + SkinCatalog.lab
        let unlockID = "skin.midnight"
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.classic, unlocked: []) == .included)
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.minimal, unlocked: []) == .included)
        #expect(SkinSelectionPolicy.availability(of: SkinCatalog.midnight, unlocked: []) == .locked)
        #expect(
            SkinSelectionPolicy.availability(of: SkinCatalog.midnight, unlocked: [unlockID]) == .unlocked
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
        let catalog = SkinCatalog.all + SkinCatalog.lab
        #expect(SkinSelectionPolicy.effectiveSkinID(requested: nil) == "classic")
        #expect(
            SkinSelectionPolicy.effectiveSkinID(
                requested: "from-a-future-build",
                unlocked: ["from-a-future-build"]
            ) == "classic"
        )
        // 打磨中的样式在正式目录里查不到,同步过来也只会回落。
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
        for skin in SkinCatalog.all + SkinCatalog.lab {
            let data = try JSONEncoder().encode(skin)
            let decoded = try JSONDecoder().decode(SkinDefinition.self, from: data)
            #expect(decoded == skin)
        }
    }
}
