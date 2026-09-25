import Foundation

/// 在某个电台上听到过的一条节目/曲目标题。
///
/// 播放器里那份 `RadioTitleHistoryEntry` 只活在这一次收听里，换台、暂停再续都会清空；
/// 这一份落盘，电台详情页的「刚播过」靠它回答「这个台最近放过什么」。
/// 只存字符串 —— 标题结构（艺术家/曲名）在写入时就拆好了，读的时候不必再解析。
public struct RadioHeardTitle: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    /// 电台推来的原文，界面直接显示。
    public var text: String
    public var artist: String?
    public var title: String?
    public var artworkURL: String?
    public var heardAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        artist: String? = nil,
        title: String? = nil,
        artworkURL: String? = nil,
        heardAt: Date
    ) {
        self.id = id
        self.text = text
        self.artist = artist
        self.title = title
        self.artworkURL = artworkURL
        self.heardAt = heardAt
    }
}

/// 一个电台的「刚播过」，最新的在最前。
public struct RadioStationHeardTitles: Codable, Equatable, Sendable {
    public var entries: [RadioHeardTitle]
    /// 最后一次写入的时间。电台数超限时按它淘汰最久没听的台。
    public var updatedAt: Date

    public init(entries: [RadioHeardTitle] = [], updatedAt: Date) {
        self.entries = entries
        self.updatedAt = updatedAt
    }
}

/// 落盘的「刚播过」怎么追加、怎么封顶。
public enum RadioHeardTitlePolicy {
    /// 每个台留的条数。电台一小时推二三十条，五十条大约是最近两小时。
    public static let maximumEntriesPerStation = 50
    /// 记多少个台。超出时淘汰最久没写入的那个 —— 用户很少回头看半年前听过一次的台。
    public static let maximumStations = 200

    /// 追加一条。和这个台最近一条是同一首（大小写、变音符、首尾空白不计）就不追加 ——
    /// 电台每隔几秒重复推送同一条，暂停再续、断线重连也会把正在放的那首再推一遍。
    ///
    /// 返回 nil 表示什么都没变，调用方不必写盘。
    public static func recording(
        _ entry: RadioHeardTitle,
        stationID: String,
        in log: [String: RadioStationHeardTitles],
        maximumEntries: Int = maximumEntriesPerStation,
        maximumStations: Int = maximumStations
    ) -> [String: RadioStationHeardTitles]? {
        let key = comparisonKey(entry.text)
        guard !key.isEmpty, !stationID.isEmpty else { return nil }

        var result = log
        var station = result[stationID] ?? RadioStationHeardTitles(updatedAt: entry.heardAt)
        if let latest = station.entries.first, comparisonKey(latest.text) == key {
            return nil
        }
        station.entries.insert(entry, at: 0)
        let cap = max(1, maximumEntries)
        if station.entries.count > cap {
            station.entries.removeLast(station.entries.count - cap)
        }
        station.updatedAt = max(station.updatedAt, entry.heardAt)
        result[stationID] = station
        return pruned(result, maximumStations: maximumStations, keeping: stationID)
    }

    /// 电台数超限时淘汰最久没写入的台。`keeping` 永远保留（刚写入的那个）。
    /// 更新时间相同的按 id 排，保证每次淘汰的是同一个。
    public static func pruned(
        _ log: [String: RadioStationHeardTitles],
        maximumStations: Int = maximumStations,
        keeping: String? = nil
    ) -> [String: RadioStationHeardTitles] {
        let cap = max(1, maximumStations)
        guard log.count > cap else { return log }
        let ordered = log.sorted { lhs, rhs in
            if lhs.key == keeping { return true }
            if rhs.key == keeping { return false }
            if lhs.value.updatedAt != rhs.value.updatedAt {
                return lhs.value.updatedAt > rhs.value.updatedAt
            }
            return lhs.key < rhs.key
        }
        return Dictionary(uniqueKeysWithValues: ordered.prefix(cap).map { ($0.key, $0.value) })
    }

    /// 读出来时清掉空台和超限条目 —— 文件可能是别的版本写的。
    public static func sanitized(
        _ log: [String: RadioStationHeardTitles],
        maximumEntries: Int = maximumEntriesPerStation,
        maximumStations: Int = maximumStations
    ) -> [String: RadioStationHeardTitles] {
        var result: [String: RadioStationHeardTitles] = [:]
        let cap = max(1, maximumEntries)
        for (stationID, station) in log where !stationID.isEmpty {
            var cleaned = station
            cleaned.entries = cleaned.entries
                .filter { !comparisonKey($0.text).isEmpty }
                .sorted { $0.heardAt > $1.heardAt }
            if cleaned.entries.count > cap {
                cleaned.entries.removeLast(cleaned.entries.count - cap)
            }
            guard !cleaned.entries.isEmpty else { continue }
            result[stationID] = cleaned
        }
        return pruned(result, maximumStations: maximumStations)
    }

    static func comparisonKey(_ text: String) -> String {
        text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 「最近收听」和首页电台条的取台规则。电台模型对这里是透明的，
/// 只要给出 id 和最近收听时间 —— 这样规则能脱离整套电台模型单独测。
public enum RadioStationRecencyPolicy {
    /// 「最近收听」一排最多放几个台。
    public static let recentLimit = 10
    /// 首页电台条最多放几个台。
    public static let stripLimit = 12

    /// 听过的台，最近的在最前。没听过的不出现；时间相同的保持传入顺序（即优先级顺序）。
    public static func recent<Item>(
        _ items: [Item],
        limit: Int = recentLimit,
        lastPlayedAt: (Item) -> Date?
    ) -> [Item] {
        guard limit > 0 else { return [] }
        let played = items.enumerated().compactMap { index, item -> (Int, Date, Item)? in
            guard let date = lastPlayedAt(item) else { return nil }
            return (index, date, item)
        }
        let sorted = played.sorted { lhs, rhs in
            lhs.1 != rhs.1 ? lhs.1 > rhs.1 : lhs.0 < rhs.0
        }
        return Array(sorted.prefix(limit).map(\.2))
    }

    /// 首页电台条：先放最近听过的，再按传入顺序（全局优先级，置顶的在前）补满。
    public static func strip<Item: Identifiable>(
        _ items: [Item],
        limit: Int = stripLimit,
        lastPlayedAt: (Item) -> Date?
    ) -> [Item] {
        guard limit > 0 else { return [] }
        var result = recent(items, limit: limit, lastPlayedAt: lastPlayedAt)
        var seen = Set(result.map(\.id))
        for item in items where result.count < limit {
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
        }
        return result
    }
}
