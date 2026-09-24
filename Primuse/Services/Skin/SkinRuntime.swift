#if os(iOS)
import Foundation
import PrimuseKit
import SwiftUI

/// 当前界面样式的唯一事实源。
///
/// 刻意不做成散在各视图里的 `@AppStorage` —— 那样每个视图各存一份原始值、
/// 各自解析、各自决定默认值,切换时机和动画也就无法统一。这里集中一处:
/// 谁在用哪套样式、哪些样式已解锁、权益变化后该退回哪套,都只有一个答案。
@MainActor
@Observable
final class SkinRuntime {
    static let selectedSkinKey = "primuse.skin.selectedID"
    static let unlockedIDsKey = "primuse.skin.unlockedIDs"

    /// 实际生效的样式。永远是一套合法且当前可用的样式 —— 选中的样式被下架、
    /// 未解锁或来自更新版本时,这里会是兜底样式,而不是半渲染状态。
    private(set) var activeSkin: SkinDefinition = SkinCatalog.fallback

    /// 用户「想用」的样式。与 `activeSkin` 分开保存:权益失效后界面回到兜底样式,
    /// 但用户的选择应当留着 —— 恢复之后不必再选一次。
    private(set) var preferredSkinID: String

    /// 已解锁的项(`SkinAccess.unlockable` 里的 unlockID),由权益来源写入。
    private(set) var unlockedIDs: Set<String>

    /// 设置页里列出来的样式。开发构建与正式构建都是 `SkinCatalog.all`;测试可以换成带待解锁皮肤的目录。
    let catalog: [SkinDefinition]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard, catalog: [SkinDefinition] = SkinCatalog.all) {
        self.defaults = defaults
        self.catalog = catalog
        let storedSkinID = defaults.string(forKey: Self.selectedSkinKey)
        // 2.0 之前「极简模式」是一个独立的导航开关;之后它并入界面样式。
        // 没选过样式的老用户,原来开着极简模式就落到极简,其余保持经典。
        let initialSkinID = SkinMigrationPolicy.initialSkinID(
            storedSkinID: storedSkinID,
            legacyNavigationModeRawValue: defaults.string(forKey: AppNavigationMode.storageKey)
        )
        self.preferredSkinID = initialSkinID
        self.unlockedIDs = Set(defaults.stringArray(forKey: Self.unlockedIDsKey) ?? [])
        if storedSkinID != initialSkinID {
            defaults.set(initialSkinID, forKey: Self.selectedSkinKey)
        }
        resolveActiveSkin()
    }

    // MARK: - 目录

    func availability(of skin: SkinDefinition) -> SkinAvailability {
        SkinSelectionPolicy.availability(of: skin, unlocked: unlockedIDs)
    }

    func isActive(_ skin: SkinDefinition) -> Bool { skin.id == activeSkin.id }

    // MARK: - 切换

    /// 选中一套样式。返回 false 表示它尚未解锁 —— 调用方据此去走解锁流程,
    /// 而不是把界面切成一个用户还没有的样子。
    @discardableResult
    func select(_ skinID: String) -> Bool {
        guard let skin = catalog.first(where: { $0.id == skinID }),
              SkinSelectionPolicy.isUsable(skin, unlocked: unlockedIDs) else {
            return false
        }
        preferredSkinID = skinID
        defaults.set(skinID, forKey: Self.selectedSkinKey)
        resolveActiveSkin()
        return true
    }

    /// 权益变化后调用。解锁会让用户之前选过的样式自动恢复;失效会让界面退回兜底样式。
    func updateEntitlements(unlocked: Set<String>) {
        guard unlocked != unlockedIDs else { return }
        unlockedIDs = unlocked
        defaults.set(Array(unlocked).sorted(), forKey: Self.unlockedIDsKey)
        resolveActiveSkin()
    }

    private func resolveActiveSkin() {
        let effectiveID = SkinSelectionPolicy.effectiveSkinID(
            requested: preferredSkinID,
            catalog: catalog,
            unlocked: unlockedIDs
        )
        let resolved = catalog.first(where: { $0.id == effectiveID }) ?? SkinCatalog.fallback
        if resolved.id != activeSkin.id {
            activeSkin = resolved
        }
        mirrorLegacyNavigationMode(for: resolved)
        publishCompanionAvailability()
        // 全 App 共用的动效词汇(`PMMotion`)从这张表取曲线。
        PMMotionSkin.motion = resolved.motion
        // CarPlay 编辑器的静态配色入口读不到环境,在这里跟着换。
        CarPlayEditorTheme.style = SkinStyle(skin: resolved)
    }

    /// 随皮肤提供的全屏效果与歌词海报,要那套皮肤可用才出现在各自的列表里。
    /// 两个目录都不知道皮肤与权益,由这里在每次变化后告诉它们。
    private func publishCompanionAvailability() {
        FullscreenEffectAvailability.update(catalog: catalog, unlocked: unlockedIDs)
        LyricPosterStyleRegistry.shared.updateSkinAvailability(catalog: catalog, unlocked: unlockedIDs)
    }

    /// 导航方式(标签栏 / 自绘顶栏)现在由样式决定。各处仍然读原来那个开关的存储键,
    /// 这里是它唯一的写入方:既省得逐处改读法,降级回旧版本时导航方式也还对得上。
    private func mirrorLegacyNavigationMode(for skin: SkinDefinition) {
        let rawValue = SkinMigrationPolicy.legacyNavigationModeRawValue(for: skin)
        if defaults.string(forKey: AppNavigationMode.storageKey) != rawValue {
            defaults.set(rawValue, forKey: AppNavigationMode.storageKey)
        }
    }

    // MARK: - 配套

    /// 全屏播放实际用哪一款效果:亲手选过的照旧;从没选过时,用当前样式带来的那一款。
    /// 选中的那一款随样式失效(权益变化、样式下架)时退回原生播放页。
    func effectiveFullscreenEffect(
        stored: FullscreenPlayerEffect,
        userSelected: Bool
    ) -> FullscreenPlayerEffect {
        let fallback = FullscreenPlayerEffect.defaultValue.rawValue
        let rawValue = SkinCompanionPolicy.resolvedStyleID(
            kind: .immersiveStage,
            userChoice: SkinCompanionPolicy.explicitChoice(
                storedStyleID: stored.rawValue,
                defaultStyleID: fallback,
                userSelected: userSelected
            ),
            activeSkin: activeSkin,
            fallbackStyleID: fallback,
            catalog: catalog,
            unlocked: unlockedIDs
        )
        return FullscreenPlayerEffect(rawValue: rawValue) ?? .defaultValue
    }

    // MARK: - 外观

    /// 样式对浅深色的要求。有些样式只在一种底色下成立,放到另一种底色会垮,
    /// 所以允许它锁定外观;跟随系统的样式不干预用户的「外观」设置。
    var enforcedColorScheme: ColorScheme? {
        switch activeSkin.appearance {
        case .adaptive: return nil
        case .forcesLight: return .light
        case .forcesDark: return .dark
        }
    }
}
#endif
