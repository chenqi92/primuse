import Foundation

/// 文件夹分组的一段。`name` 为 nil 表示「未分组」。
public struct RadioStationFolderGroup: Identifiable, Hashable, Sendable {
    public let name: String?
    public let stations: [RadioStation]

    public init(name: String?, stations: [RadioStation]) {
        self.name = name
        self.stations = stations
    }

    /// 文件夹名不可能为空串(归一化时就被挡掉了)，所以空串可以安全地代表未分组。
    public var id: String { name ?? "" }
    public var isUngrouped: Bool { name == nil }
}

/// 一个文件夹连同它当前装了多少个电台。空文件夹的 `stationCount` 是 0。
public struct RadioStationFolderSummary: Identifiable, Hashable, Sendable {
    public let name: String
    public let stationCount: Int

    public init(name: String, stationCount: Int) {
        self.name = name
        self.stationCount = stationCount
    }

    public var id: String { name }
    public var isEmpty: Bool { stationCount == 0 }
}

/// 一个标签连同它贴在多少个电台上。
public struct RadioStationTagSummary: Identifiable, Hashable, Sendable {
    public let name: String
    public let stationCount: Int

    public init(name: String, stationCount: Int) {
        self.name = name
        self.stationCount = stationCount
    }

    public var id: String { name }
}

/// 电台列表的筛选条件：一个文件夹范围 + 若干标签 + 一段搜索词。
public struct RadioStationFilter: Hashable, Sendable {
    public enum FolderScope: Hashable, Sendable {
        case all
        case ungrouped
        case folder(String)
    }

    public var folder: FolderScope
    /// 多个标签取**交集** —— 加一个标签是「再缩小一点」，这符合筛选的直觉。
    public var tagNames: Set<String>
    public var searchText: String

    public init(
        folder: FolderScope = .all,
        tagNames: Set<String> = [],
        searchText: String = ""
    ) {
        self.folder = folder
        self.tagNames = tagNames
        self.searchText = searchText
    }

    public static let unfiltered = RadioStationFilter()

    public var isNarrowed: Bool {
        if case .all = folder {} else { return true }
        return !tagNames.isEmpty
            || !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// 电台的「文件夹 + 标签」组织模型。
///
/// 两者都**不另建一张注册表**：文件夹名和标签名就写在电台自己身上，现有的
/// 文件夹/标签集合由全部电台归纳得出。这样整套组织信息跟着电台记录一起走 ——
/// 落盘、CloudKit 记录、局域网快照都不必新增实体，两台设备各自建了同名文件夹
/// 也会自然合并成一个，而不是留下两个看起来一样的条目。
///
/// 代价是空文件夹没有存身之处。界面上「先建文件夹再往里放」的那一步由
/// `RadioStationsStore` 的本机占位清单兜住，装进第一个电台后它就名副其实了。
public enum RadioStationOrganization {
    public static let maximumFolderNameLength = 60
    public static let maximumTagNameLength = 32
    /// 一个电台最多贴这么多标签。再多就不是分类而是备注了，而且每个标签都要
    /// 跟着电台进同步记录。
    public static let maximumTagsPerStation = 12

    // MARK: - 归一化

    /// 文件夹名的归一化：去首尾空白、内部连续空白压成一个空格、丢掉控制字符，
    /// 超长截断。归一化不出东西(空串)就返回 nil —— 调用方据此理解为「没有文件夹」。
    public static func normalizedFolderName(_ raw: String?) -> String? {
        normalized(raw, limit: maximumFolderNameLength)
    }

    public static func normalizedTagName(_ raw: String?) -> String? {
        normalized(raw, limit: maximumTagNameLength)
    }

    /// 归一化一组标签：逐个清洗、按不区分大小写去重(保留先出现的那个写法)、
    /// 保持用户给的顺序、超出上限的丢弃。结果为空时返回 nil，好让电台记录里
    /// 不留一个空数组。
    public static func normalizedTagNames(_ raw: [String]?) -> [String]? {
        guard let raw else { return nil }
        var seen: Set<String> = []
        var result: [String] = []
        for value in raw {
            guard let name = normalizedTagName(value) else { continue }
            guard seen.insert(comparisonKey(name)).inserted else { continue }
            result.append(name)
            if result.count >= maximumTagsPerStation { break }
        }
        return result.isEmpty ? nil : result
    }

    /// 比较用的规范键。用户不该因为大小写、全角半角或者重音记号的差别，
    /// 得到两个看起来一模一样的文件夹。
    public static func comparisonKey(_ name: String) -> String {
        name.folding(
            options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive],
            locale: nil
        )
    }

    public static func isSameName(_ lhs: String, _ rhs: String) -> Bool {
        comparisonKey(lhs) == comparisonKey(rhs)
    }

    private static func normalized(_ raw: String?, limit: Int) -> String? {
        guard let raw else { return nil }
        let stripped = String(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })
        let collapsed = stripped
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > limit else { return collapsed }
        return String(collapsed.prefix(limit))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 归纳现有的文件夹与标签

    /// 全部电台里出现过的文件夹，按名称排序。`additionalNames` 是本机的空文件夹
    /// 占位，已经有电台的同名占位不会重复出现。
    public static func folders(
        in stations: [RadioStation],
        additionalNames: [String] = []
    ) -> [RadioStationFolderSummary] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for station in stations {
            guard let name = normalizedFolderName(station.folderName) else { continue }
            let key = comparisonKey(name)
            counts[key, default: 0] += 1
            if display[key] == nil { display[key] = name }
        }
        for value in additionalNames {
            guard let name = normalizedFolderName(value) else { continue }
            let key = comparisonKey(name)
            if display[key] == nil {
                display[key] = name
                counts[key] = 0
            }
        }
        return display
            .map { RadioStationFolderSummary(name: $0.value, stationCount: counts[$0.key] ?? 0) }
            .sorted { orderedAscending($0.name, $1.name) }
    }

    /// 没有归入任何文件夹的电台数量。
    public static func ungroupedCount(in stations: [RadioStation]) -> Int {
        stations.reduce(into: 0) { total, station in
            if normalizedFolderName(station.folderName) == nil { total += 1 }
        }
    }

    /// 全部电台里出现过的标签，按名称排序。
    public static func tags(in stations: [RadioStation]) -> [RadioStationTagSummary] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for station in stations {
            for name in station.assignedTagNames {
                let key = comparisonKey(name)
                counts[key, default: 0] += 1
                if display[key] == nil { display[key] = name }
            }
        }
        return display
            .map { RadioStationTagSummary(name: $0.value, stationCount: counts[$0.key] ?? 0) }
            .sorted { orderedAscending($0.name, $1.name) }
    }

    private static func orderedAscending(_ lhs: String, _ rhs: String) -> Bool {
        let result = lhs.localizedStandardCompare(rhs)
        return result == .orderedSame ? lhs < rhs : result == .orderedAscending
    }

    // MARK: - 筛选与分组

    /// 按筛选条件过滤，保持传入顺序 —— 电台的优先级顺序是用户排出来的，
    /// 筛选只做减法，不重排。
    public static func filtered(
        _ stations: [RadioStation],
        with filter: RadioStationFilter
    ) -> [RadioStation] {
        let tagKeys = Set(filter.tagNames.map(comparisonKey))
        let queryTokens = searchTokens(filter.searchText)
        return stations.filter { station in
            matchesFolder(station, scope: filter.folder)
                && matchesTags(station, tagKeys: tagKeys)
                && matchesQuery(station, tokens: queryTokens)
        }
    }

    /// 按文件夹切成几段，未分组的永远排在最后。段内顺序保持传入顺序。
    public static func grouped(_ stations: [RadioStation]) -> [RadioStationFolderGroup] {
        var order: [String] = []
        var display: [String: String] = [:]
        var buckets: [String: [RadioStation]] = [:]
        var ungrouped: [RadioStation] = []

        for station in stations {
            guard let name = normalizedFolderName(station.folderName) else {
                ungrouped.append(station)
                continue
            }
            let key = comparisonKey(name)
            if display[key] == nil {
                display[key] = name
                order.append(key)
            }
            buckets[key, default: []].append(station)
        }

        var groups = order
            .map { RadioStationFolderGroup(name: display[$0], stations: buckets[$0] ?? []) }
            .sorted { orderedAscending($0.name ?? "", $1.name ?? "") }
        if !ungrouped.isEmpty {
            groups.append(RadioStationFolderGroup(name: nil, stations: ungrouped))
        }
        return groups
    }

    private static func matchesFolder(
        _ station: RadioStation,
        scope: RadioStationFilter.FolderScope
    ) -> Bool {
        switch scope {
        case .all:
            return true
        case .ungrouped:
            return normalizedFolderName(station.folderName) == nil
        case .folder(let name):
            guard let current = normalizedFolderName(station.folderName) else { return false }
            return isSameName(current, name)
        }
    }

    private static func matchesTags(_ station: RadioStation, tagKeys: Set<String>) -> Bool {
        guard !tagKeys.isEmpty else { return true }
        let own = Set(station.assignedTagNames.map(comparisonKey))
        return tagKeys.isSubset(of: own)
    }

    /// 搜索词按空白切成若干块，每一块都要命中 —— 「jazz 爵士」应该收窄结果，
    /// 而不是把两个词的结果并起来。
    public static func searchTokens(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .map(comparisonKey)
    }

    public static func matchesQuery(_ station: RadioStation, tokens: [String]) -> Bool {
        guard !tokens.isEmpty else { return true }
        var haystack = [station.name, station.displayEndpoint, station.streamURL]
        if let folder = normalizedFolderName(station.folderName) { haystack.append(folder) }
        haystack.append(contentsOf: station.assignedTagNames)
        let folded = haystack.map(comparisonKey)
        return tokens.allSatisfy { token in
            folded.contains { $0.contains(token) }
        }
    }

    // MARK: - 标签数组的增删改

    /// 三个编辑函数统一返回这个 —— `unchanged` 让调用方跳过一次写盘和一次
    /// 同步入队，而不是把「没变」和「变成了空」混在一个 `nil` 里。
    public enum TagEdit: Equatable, Sendable {
        case unchanged
        case updated([String]?)
    }

    public static func adding(tag: String, to current: [String]?) -> TagEdit {
        guard let name = normalizedTagName(tag) else { return .unchanged }
        let existing = current ?? []
        guard !existing.contains(where: { isSameName($0, name) }),
              existing.count < maximumTagsPerStation else { return .unchanged }
        return .updated(normalizedTagNames(existing + [name]))
    }

    public static func removing(tag: String, from current: [String]?) -> TagEdit {
        guard let name = normalizedTagName(tag), let existing = current else { return .unchanged }
        let kept = existing.filter { !isSameName($0, name) }
        guard kept.count != existing.count else { return .unchanged }
        return .updated(normalizedTagNames(kept))
    }

    public static func renaming(
        tag: String,
        to newName: String,
        in current: [String]?
    ) -> TagEdit {
        guard let old = normalizedTagName(tag),
              let new = normalizedTagName(newName),
              let existing = current,
              existing.contains(where: { isSameName($0, old) }) else { return .unchanged }
        let normalized = normalizedTagNames(existing.map { isSameName($0, old) ? new : $0 })
        guard (normalized ?? []) != existing else { return .unchanged }
        return .updated(normalized)
    }

    // MARK: - 标签配色

    /// 标签颜色从名字算出来，不落库 —— 同一个标签在每台设备、每次启动都是
    /// 同一个颜色，而用户不必为此做任何选择。
    public static func paletteIndex(forTag name: String, paletteSize: Int) -> Int {
        guard paletteSize > 0 else { return 0 }
        let hash = StableFNV1a64.hash(comparisonKey(name))
        return Int(hash % UInt64(paletteSize))
    }
}

/// 服务端电台镜像落在哪个文件夹。服务端自己把台分了文件夹的(Audio Station 的
/// 「我的最爱」与自己添加的台),镜像放进「源名 / 服务端文件夹」—— 电台页的文件夹
/// 只有一层,两层靠名字拼起来。
public enum ServerRadioFolderPolicy {
    public static let separator = " / "

    public static func folderName(sourceName: String, serverFolderName: String?) -> String? {
        guard let folder = RadioStationOrganization.normalizedFolderName(serverFolderName) else { return nil }
        guard let source = RadioStationOrganization.normalizedFolderName(sourceName) else { return folder }
        // 超长时截源名,保住服务端文件夹那一段:同一个源下的几个文件夹靠它区分。
        let room = RadioStationOrganization.maximumFolderNameLength - separator.count - folder.count
        let prefix = String(source.prefix(max(0, room))).trimmingCharacters(in: .whitespaces)
        guard !prefix.isEmpty else { return folder }
        return RadioStationOrganization.normalizedFolderName(prefix + separator + folder)
    }

    /// 文件夹归用户整理。新镜像用同步给的文件夹;已有的只在还停在同步给过的某个
    /// 文件夹里(用户没挪过)时,跟着服务端换到新的那个,挪走或移出文件夹的都不动。
    public static func reconciledFolderName(
        current: String?,
        isNewMirror: Bool,
        assigned: String?,
        syncManagedFolderNames: [String]
    ) -> String? {
        if isNewMirror { return assigned }
        guard let currentName = RadioStationOrganization.normalizedFolderName(current),
              let assigned,
              !RadioStationOrganization.isSameName(currentName, assigned),
              syncManagedFolderNames.contains(where: { RadioStationOrganization.isSameName($0, currentName) }) else {
            return current
        }
        return assigned
    }
}
