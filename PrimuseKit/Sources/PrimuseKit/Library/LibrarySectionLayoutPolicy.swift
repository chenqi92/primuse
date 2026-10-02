import Foundation

/// 资料库分类(经典外壳的资料库首页、极简外壳的顶栏胶囊、iPad / Mac 侧栏共用一份)
/// 的顺序与显隐存档规则。分类本身定义在 App 里,这里按分类的 rawValue 处理,
/// 所以泛型参数只要求能和字符串互转。
///
/// 两个存档都是 JSON 字符串数组,只存本机:
/// - 顺序:用户拖过就存完整顺序;从没拖过是空串,跟着默认顺序走。
/// - 隐藏:空串表示「从没设过」,用默认隐藏的那几类;设过就照存的来(`[]` 也算设过)。
///
/// 默认隐藏是后来才有的:在那之前空串的意思是「全部显示」。升级时已经自定义过
/// 资料库的人(顺序存过值)不能因为新默认而少掉原本看得到的分类,见 `upgradeAction`。
public enum LibrarySectionLayoutPolicy {
    public static let orderKey = "primuse.library.sectionOrder.v1"
    public static let hiddenKey = "primuse.library.hiddenSections.v1"
    /// 「空串 = 默认隐藏」这条规则对这台设备生效过的标记。只在第一次启动新版本时判一次。
    public static let defaultHiddenMigrationKey = "primuse.library.defaultHiddenSections.v2"

    // MARK: 顺序

    /// 存档里的顺序补成完整顺序:先去掉重复与认不出的,再把存档里没有的分类
    /// (新版本加的)插到默认顺序里它前一个邻居的后面;前面没有邻居就放最前。
    /// 这样新分类出现在用户熟悉的位置旁边,而不是被挤到列表最前或最后。
    public static func completedOrder<Section: Hashable>(
        _ stored: [Section],
        defaultOrder: [Section]
    ) -> [Section] {
        let known = Set(defaultOrder)
        var seen = Set<Section>()
        var order = stored.filter { known.contains($0) && seen.insert($0).inserted }
        for (defaultIndex, section) in defaultOrder.enumerated() where !seen.contains(section) {
            let anchor = defaultOrder[..<defaultIndex].reversed().first { seen.contains($0) }
            let insertAt = anchor.flatMap { order.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            order.insert(section, at: insertAt)
            seen.insert(section)
        }
        return order
    }

    // MARK: 隐藏

    /// 用户设过的隐藏集合;没设过(空串)或存档坏了返回 nil,调用方用默认隐藏。
    public static func storedHidden<Section: Hashable>(
        _ rawValue: String,
        section: (String) -> Section?
    ) -> Set<Section>? {
        guard let names = decodeNames(rawValue) else { return nil }
        return Set(names.compactMap(section))
    }

    /// 实际隐藏的分类。
    public static func hidden<Section: Hashable>(
        rawValue: String,
        defaultHidden: Set<Section>,
        section: (String) -> Section?
    ) -> Set<Section> {
        storedHidden(rawValue, section: section) ?? defaultHidden
    }

    // MARK: 升级

    public enum UpgradeAction: Equatable, Sendable {
        /// 什么都不用写。
        case none
        /// 把隐藏存档写成 `[]`:这个人在旧版本里所有分类都看得到,升级后保持原样。
        case keepEverythingVisible
    }

    /// 第一次启动带默认隐藏的版本时要不要改写隐藏存档。
    ///
    /// - 隐藏存档已经有值:用户自己设过显隐,照旧。
    /// - 隐藏存档是空的、顺序存档有值:用户调过资料库的顺序,只是没关过任何分类。
    ///   旧版本里空串就是「全部显示」,得把这个状态写实,否则默认隐藏的两类会凭空消失。
    /// - 两个存档都空:新装或从没动过,直接用新的默认。
    public static func upgradeAction(
        storedOrderRawValue: String?,
        storedHiddenRawValue: String?,
        alreadyMigrated: Bool
    ) -> UpgradeAction {
        guard !alreadyMigrated else { return .none }
        let hasStoredHidden = !(storedHiddenRawValue ?? "").isEmpty
        let hasStoredOrder = !(storedOrderRawValue ?? "").isEmpty
        guard !hasStoredHidden, hasStoredOrder else { return .none }
        return .keepEverythingVisible
    }

    /// 在 UserDefaults 上做一次 `upgradeAction`。启动时、任何界面读这两个键之前调用。
    @discardableResult
    public static func migrateDefaultHiddenIfNeeded(defaults: UserDefaults = .standard) -> UpgradeAction {
        let action = upgradeAction(
            storedOrderRawValue: defaults.string(forKey: orderKey),
            storedHiddenRawValue: defaults.string(forKey: hiddenKey),
            alreadyMigrated: defaults.bool(forKey: defaultHiddenMigrationKey)
        )
        switch action {
        case .none:
            break
        case .keepEverythingVisible:
            defaults.set(encodeNames([]), forKey: hiddenKey)
        }
        if !defaults.bool(forKey: defaultHiddenMigrationKey) {
            defaults.set(true, forKey: defaultHiddenMigrationKey)
        }
        return action
    }

    // MARK: 存档格式

    /// 解出存档里的名字;空串或不是字符串数组时返回 nil。
    /// 按字符串解:以后删掉的分类、更新的版本写进来的新分类都只丢那一项。
    public static func decodeNames(_ rawValue: String) -> [String]? {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        return names
    }

    public static func encodeNames(_ names: [String]) -> String {
        guard let data = try? JSONEncoder().encode(names) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
