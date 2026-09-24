import Foundation

extension SkinMetricToken {
    /// 取值必须落在 0...1 的几何位(目前只有阴影不透明度)。其余是点值。
    public var isUnitInterval: Bool { self == .shadowOpacity }

    /// 是否随 Dynamic Type 放大。
    ///
    /// 控件高度、图标尺寸要跟着字号长,否则大字号下文字会顶出控件。圆角、描边、阴影不跟 ——
    /// 它们是形状语言的一部分,跟着字号变会让同一套样式在不同字号下看起来像两套设计。
    /// 间距与内边距也不跟:视图里原有的 `padding` / `spacing` 都是固定值,系统控件的默认
    /// 间距同样不随字号变,跟着放大只会在大字号下白白挤掉内容的宽度。
    /// 这与视图里 `@ScaledMetric` 的原有用法一致(高度用,圆角与间距不用)。
    public var scalesWithDynamicType: Bool {
        switch self {
        case .controlHeightSmall, .controlHeightMedium, .controlHeightLarge,
             .iconSizeSmall, .iconSizeMedium, .iconSizeLarge,
             .chromeChipHeight, .chromeChipRowHeight, .chromeCollapsedChipHeight,
             .chromeSearchFieldHeight:
            return true
        case .radiusSmall, .radiusMedium, .radiusLarge, .radiusChip, .radiusCard, .radiusArtwork,
             .radiusPill, .hairline, .borderWidth, .shadowRadius, .shadowOpacity,
             .spacingTight, .spacingSmall, .spacingMedium, .spacingLarge, .spacingSection,
             .chromeTopPadding, .chromeBottomPadding, .chromeItemSpacing, .chromeChipSpacing,
             .chromeChipRowSpacing, .chromeHorizontalInset:
            return false
        }
    }

    /// 缩放时对齐的文本样式。
    public var scalingAnchor: SkinTextStyle {
        switch self {
        case .spacingSection, .controlHeightLarge, .iconSizeLarge:
            return .body
        default:
            return .subheadline
        }
    }
}

public enum SkinValidationIssue: Sendable, Equatable {
    case missingColor(skinID: String, token: SkinColorToken)
    case missingMetric(skinID: String, token: SkinMetricToken)
    case missingTypography(skinID: String, token: SkinTypographyToken)
    case missingMotion(skinID: String, token: SkinMotionToken)
    case malformedColor(skinID: String, token: SkinColorToken)
    case malformedMetric(skinID: String, token: SkinMetricToken)
    case malformedTypography(skinID: String, token: SkinTypographyToken)
    case malformedMotion(skinID: String, token: SkinMotionToken)
    case unregisteredSlotVariant(skinID: String, slot: SkinSlot, variant: SkinSlotVariantID)
    /// 样式声明了一个目录里不存在的配套舞台 / 海报。
    case unknownCompanion(skinID: String, kind: SkinCompanionKind, styleID: String)
    /// 建议启用的配套不在它自己带来的列表里。
    case preferredCompanionNotIncluded(skinID: String, kind: SkinCompanionKind, styleID: String)
    case emptyUnlockID(skinID: String)
    case duplicateSkinID(String)
    case missingFallbackSkin(id: String)
    case fallbackSkinRequiresUnlock(id: String)
}

/// 样式定义的完整性校验。
///
/// 一套样式少定义一个 token,在运行时表现为「某个控件颜色突然回到兜底值」——
/// 这种缺陷靠肉眼走查发现不了,所以把它变成一条可在本机跑的断言:
/// 每套样式都必须给出全部 token,插槽只能引用登记过的实现,配套只能引用存在的款式。
public enum SkinValidationPolicy {
    /// - Parameters:
    ///   - knownImmersiveStageIDs / knownLyricPosterStyleIDs: 传 nil 表示这次不校验该类配套
    ///     (舞台目录在 App 层,Kit 内的调用方拿不到时就跳过)。
    public static func issues(
        in skin: SkinDefinition,
        registry: [SkinSlot: Set<SkinSlotVariantID>] = SkinSlotRegistry.builtIn,
        knownImmersiveStageIDs: Set<String>? = nil,
        knownLyricPosterStyleIDs: Set<String>? = nil
    ) -> [SkinValidationIssue] {
        var issues: [SkinValidationIssue] = []

        for token in SkinColorToken.allCases {
            guard let spec = skin.colors[token] else {
                issues.append(.missingColor(skinID: skin.id, token: token))
                continue
            }
            if !spec.isWellFormed {
                issues.append(.malformedColor(skinID: skin.id, token: token))
            }
        }

        for token in SkinMetricToken.allCases {
            guard let value = skin.metrics[token] else {
                issues.append(.missingMetric(skinID: skin.id, token: token))
                continue
            }
            let valid = value.isFinite
                && (token.isUnitInterval ? (0...1).contains(value) : value >= 0)
            if !valid {
                issues.append(.malformedMetric(skinID: skin.id, token: token))
            }
        }

        for token in SkinTypographyToken.allCases {
            guard let spec = skin.typography[token] else {
                issues.append(.missingTypography(skinID: skin.id, token: token))
                continue
            }
            if !spec.isWellFormed {
                issues.append(.malformedTypography(skinID: skin.id, token: token))
            }
        }

        for token in SkinMotionToken.allCases {
            guard let spec = skin.motion[token] else {
                issues.append(.missingMotion(skinID: skin.id, token: token))
                continue
            }
            if !spec.isWellFormed {
                issues.append(.malformedMotion(skinID: skin.id, token: token))
            }
        }

        for slot in SkinSlot.allCases {
            let variant = skin.variant(for: slot)
            guard registry[slot]?.contains(variant) == true else {
                issues.append(
                    .unregisteredSlotVariant(skinID: skin.id, slot: slot, variant: variant)
                )
                continue
            }
        }

        if let unlockID = skin.access.unlockID,
           unlockID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.emptyUnlockID(skinID: skin.id))
        }

        issues.append(
            contentsOf: companionIssues(
                skinID: skin.id,
                kind: .immersiveStage,
                declared: skin.companions.immersiveStageIDs,
                preferred: skin.companions.preferredImmersiveStageID,
                known: knownImmersiveStageIDs
            )
        )
        issues.append(
            contentsOf: companionIssues(
                skinID: skin.id,
                kind: .lyricPoster,
                declared: skin.companions.lyricPosterStyleIDs,
                preferred: skin.companions.preferredLyricPosterStyleID,
                known: knownLyricPosterStyleIDs
            )
        )

        return issues
    }

    private static func companionIssues(
        skinID: String,
        kind: SkinCompanionKind,
        declared: [String],
        preferred: String?,
        known: Set<String>?
    ) -> [SkinValidationIssue] {
        var issues: [SkinValidationIssue] = []
        if let known {
            for styleID in declared where !known.contains(styleID) {
                issues.append(.unknownCompanion(skinID: skinID, kind: kind, styleID: styleID))
            }
        }
        if let preferred, !declared.contains(preferred) {
            issues.append(
                .preferredCompanionNotIncluded(skinID: skinID, kind: kind, styleID: preferred)
            )
        }
        return issues
    }

    public static func catalogIssues(
        _ catalog: [SkinDefinition] = SkinCatalog.all + SkinCatalog.lab,
        registry: [SkinSlot: Set<SkinSlotVariantID>] = SkinSlotRegistry.builtIn,
        fallbackID: String = SkinCatalog.classicID,
        knownImmersiveStageIDs: Set<String>? = nil,
        knownLyricPosterStyleIDs: Set<String>? = nil
    ) -> [SkinValidationIssue] {
        var found: [SkinValidationIssue] = catalog.flatMap {
            issues(
                in: $0,
                registry: registry,
                knownImmersiveStageIDs: knownImmersiveStageIDs,
                knownLyricPosterStyleIDs: knownLyricPosterStyleIDs
            )
        }

        var seen: Set<String> = []
        for skin in catalog where !seen.insert(skin.id).inserted {
            found.append(.duplicateSkinID(skin.id))
        }

        guard let fallback = catalog.first(where: { $0.id == fallbackID }) else {
            found.append(.missingFallbackSkin(id: fallbackID))
            return found
        }
        // 兜底样式一旦需要解锁,没解锁的用户就会被锁在一个无法渲染的状态里。
        if fallback.access.requiresUnlock {
            found.append(.fallbackSkinRequiresUnlock(id: fallback.id))
        }
        return found
    }
}

// MARK: - 选择与可用性

/// 一套样式对当前用户的可用状态。
public enum SkinAvailability: Sendable, Equatable {
    /// 随 App 提供,随时可用。
    case included
    /// 需要解锁且已解锁。
    case unlocked
    /// 需要解锁且尚未解锁 —— 可以预览,但不能设为当前样式。
    case locked
}

/// 「当前该用哪套样式」的唯一判定。
///
/// 独立成纯函数是因为它要处理的边界都发生在看不见的地方:样式被下架、权益失效、
/// 用户换设备后同步过来一个本机没有的样式 id。这些路径不能靠打开 App 用肉眼验证,
/// 必须能在本机断言。
public enum SkinSelectionPolicy {
    public static func availability(
        of skin: SkinDefinition,
        unlocked: Set<String>
    ) -> SkinAvailability {
        guard let unlockID = skin.access.unlockID else { return .included }
        return unlocked.contains(unlockID) ? .unlocked : .locked
    }

    public static func isUsable(_ skin: SkinDefinition, unlocked: Set<String>) -> Bool {
        availability(of: skin, unlocked: unlocked) != .locked
    }

    /// 解析出实际生效的样式 id。任何异常情况都回落到兜底样式,而不是让界面
    /// 停在半渲染状态。
    public static func effectiveSkinID(
        requested: String?,
        catalog: [SkinDefinition] = SkinCatalog.all,
        unlocked: Set<String> = [],
        fallbackID: String = SkinCatalog.classicID
    ) -> String {
        guard let requested,
              let skin = catalog.first(where: { $0.id == requested }),
              isUsable(skin, unlocked: unlocked) else {
            return fallbackID
        }
        return skin.id
    }

    /// 权益变化之后,当前选择是否必须换掉。
    public static func requiresFallback(
        current: String?,
        catalog: [SkinDefinition] = SkinCatalog.all,
        unlocked: Set<String> = [],
        fallbackID: String = SkinCatalog.classicID
    ) -> Bool {
        effectiveSkinID(
            requested: current,
            catalog: catalog,
            unlocked: unlocked,
            fallbackID: fallbackID
        ) != current
    }
}

// MARK: - 从「极简模式」迁移

/// 2.0 之前,「极简模式」是外观设置里一个独立的导航开关;之后它并入界面样式。
public enum SkinMigrationPolicy {
    /// 旧开关的存储值(`AppNavigationMode.minimal.rawValue`)。
    public static let legacyMinimalNavigationRawValue = "minimal"
    public static let legacyStandardNavigationRawValue = "standard"

    /// 首次运行新版本时用户应落在哪套样式上。
    ///
    /// 已经选过样式的人不动;没选过的,原来开着极简模式就落到极简,其余保持经典 ——
    /// 升级不应该替任何人换掉他正在用的导航方式。
    public static func initialSkinID(
        storedSkinID: String?,
        legacyNavigationModeRawValue: String?
    ) -> String {
        if let storedSkinID, !storedSkinID.isEmpty { return storedSkinID }
        if legacyNavigationModeRawValue == legacyMinimalNavigationRawValue {
            return SkinCatalog.minimalID
        }
        return SkinCatalog.classicID
    }

    /// 写回旧开关的值。旧版本(或从备份恢复到旧版本)读到它,导航方式仍与用户的选择一致。
    public static func legacyNavigationModeRawValue(for skin: SkinDefinition) -> String {
        switch skin.navigationHeader {
        case .classic: return legacyStandardNavigationRawValue
        case .topTabs: return legacyMinimalNavigationRawValue
        }
    }
}

// MARK: - 配套

public enum SkinCompanionKind: String, Sendable, Codable, CaseIterable {
    case immersiveStage
    case lyricPoster
}

/// 配套舞台 / 海报的可用性。
///
/// 舞台与海报各有自己的目录,这里不接管它们,只回答一个问题:
/// 「这一款现在能不能用」—— 没有任何样式认领的款式是基础款,始终可用;
/// 被样式认领的款式,只要有一套认领它的样式可用就可用。
public enum SkinCompanionPolicy {
    public static func styleIDs(of kind: SkinCompanionKind, in skin: SkinDefinition) -> [String] {
        switch kind {
        case .immersiveStage: return skin.companions.immersiveStageIDs
        case .lyricPoster: return skin.companions.lyricPosterStyleIDs
        }
    }

    public static func owners(
        of styleID: String,
        kind: SkinCompanionKind,
        catalog: [SkinDefinition] = SkinCatalog.all
    ) -> [SkinDefinition] {
        catalog.filter { styleIDs(of: kind, in: $0).contains(styleID) }
    }

    public static func isAvailable(
        styleID: String,
        kind: SkinCompanionKind,
        catalog: [SkinDefinition] = SkinCatalog.all,
        unlocked: Set<String> = []
    ) -> Bool {
        let owners = owners(of: styleID, kind: kind, catalog: catalog)
        guard !owners.isEmpty else { return true }
        return owners.contains { SkinSelectionPolicy.isUsable($0, unlocked: unlocked) }
    }

    /// 从一组款式里筛掉当前不可用的,顺序不变。
    public static func availableStyleIDs(
        from styleIDs: [String],
        kind: SkinCompanionKind,
        catalog: [SkinDefinition] = SkinCatalog.all,
        unlocked: Set<String> = []
    ) -> [String] {
        styleIDs.filter {
            isAvailable(styleID: $0, kind: kind, catalog: catalog, unlocked: unlocked)
        }
    }

    /// 一个「总是有值」的存储项算不算用户的选择。
    ///
    /// 全屏效果的存储键在启动时就会被写成默认值,「从没选过」没法靠键是否存在来判断。
    /// 亲手选过(`userSelected`),或者存储值已经不是默认值(另一台设备同步过来的选择),
    /// 才算用户的选择;否则返回 nil,交给当前样式建议的那一款。
    public static func explicitChoice(
        storedStyleID: String,
        defaultStyleID: String,
        userSelected: Bool
    ) -> String? {
        if userSelected || storedStyleID != defaultStyleID { return storedStyleID }
        return nil
    }

    /// 当前该用哪一款。
    ///
    /// - 用户手动选过且那一款仍可用:尊重用户的选择。
    /// - 选过的款式已不可用(权益失效、样式下架):退到 `fallbackStyleID`。
    /// - 从没选过:用当前样式建议的那一款,没有建议就用 `fallbackStyleID`。
    public static func resolvedStyleID(
        kind: SkinCompanionKind,
        userChoice: String?,
        activeSkin: SkinDefinition,
        fallbackStyleID: String,
        catalog: [SkinDefinition] = SkinCatalog.all,
        unlocked: Set<String> = []
    ) -> String {
        if let userChoice, !userChoice.isEmpty {
            return isAvailable(styleID: userChoice, kind: kind, catalog: catalog, unlocked: unlocked)
                ? userChoice
                : fallbackStyleID
        }
        let preferred: String?
        switch kind {
        case .immersiveStage: preferred = activeSkin.companions.preferredImmersiveStageID
        case .lyricPoster: preferred = activeSkin.companions.preferredLyricPosterStyleID
        }
        if let preferred,
           isAvailable(styleID: preferred, kind: kind, catalog: catalog, unlocked: unlocked) {
            return preferred
        }
        return fallbackStyleID
    }
}
