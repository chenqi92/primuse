import Foundation
import PrimuseKit

/// 智能歌单规则引擎: 给定一份 SmartPlaylist 定义和当前 library / 播放历史,
/// 算出匹配的 Song 列表 (按 sortField/sortDirection 排序, 按 limit 截断)。
///
/// 设计选择: 纯 in-memory filter, 不走 GRDB SQL。
/// - `MusicLibrary.visibleSongs` 已经在内存里 (snapshot 加载到数组)
/// - 几千首歌 × 几条规则的 filter / sort 在主线程几十 ms 内完成
/// - 跟 SQL 比省了一层 schema / 类型转换 / 后处理 join 的复杂度
/// - 规则数量上限不再是 SQL OR 拖死的问题, 而是用户可读性问题
///
/// PlayHistoryStore 数据 (playCount / lastPlayedAt) 一次性聚合成字典,
/// 所有规则共用 ── 不每条规则重算一遍。
@MainActor
enum SmartPlaylistEngine {
    /// 从 library 当前快照里查出匹配 smart 定义的歌曲列表。
    static func match(
        _ smart: SmartPlaylist,
        in library: MusicLibrary,
        history: PlayHistoryStore
    ) -> [Song] {
        let startedAt = Date()
        let songs = candidateSongs(in: library)
        let totalSongs = songs.count

        let ruleGroups = smart.effectiveRuleGroups

        // 空规则集合: 命中 library 全部 (用户可能新建后还没编辑规则就先看个全量)
        guard !ruleGroups.isEmpty else {
            let result = sortAndLimit(songs, smart: smart, history: history)
            let elapsed = Date().timeIntervalSince(startedAt)
            plog(String(format: "🎯 SmartPlaylist '%@' match: 0 rules → matched=%d/%d in %.0fms",
                        smart.name, result.count, totalSongs, elapsed * 1000))
            return result
        }

        let stats = PlayStats(history: history)

        let groupCombinator = smart.effectiveGroupCombinator
        let matched = songs.filter { song in
            evaluate(groups: ruleGroups, groupCombinator: groupCombinator,
                     song: song, stats: stats, library: library)
        }
        let result = sortAndLimit(matched, smart: smart, history: history)
        let elapsed = Date().timeIntervalSince(startedAt)
        let ruleCount = ruleGroups.reduce(0) { $0 + $1.rules.count }
        plog(String(format: "🎯 SmartPlaylist '%@' match: groups=%d rules=%d sortBy=%@ limit=%@ → matched=%d/%d (truncated to %d) in %.0fms",
                    smart.name,
                    ruleGroups.count,
                    ruleCount,
                    smart.sortField.rawValue,
                    smart.limit.map(String.init) ?? "none",
                    matched.count, totalSongs, result.count,
                    elapsed * 1000))
        return result
    }

    private static func candidateSongs(in library: MusicLibrary) -> [Song] {
        guard !AppleMusicFeatureSettings.autoAddToSmartPlaylistsEnabled else {
            return library.visibleSongs
        }
        return library.visibleSongs.filter { $0.sourceID != AppleMusicLibraryService.systemSourceID }
    }

    // MARK: - Rule evaluation

    private static func evaluate(
        groups: [SmartPlaylistRuleGroup],
        groupCombinator: SmartPlaylistCombinator,
        song: Song,
        stats: PlayStats,
        library: MusicLibrary
    ) -> Bool {
        // 空组 (无规则) 不参与组合 —— AND 下它是中性的, OR 下让它返回 true 会
        // 把全部命中, 语义都不对, 直接剔除。剔完没组了 = 没有有效规则 = 命中全部。
        let activeGroups = groups.filter { !$0.rules.isEmpty }
        guard !activeGroups.isEmpty else { return true }

        let matches: (SmartPlaylistRuleGroup) -> Bool = { group in
            let matched = evaluate(
                rules: group.rules,
                combinator: group.combinator,
                song: song,
                stats: stats,
                library: library
            )
            return group.isExcluded ? !matched : matched
        }

        switch groupCombinator {
        case .and:
            return activeGroups.allSatisfy(matches)
        case .or:
            return activeGroups.contains(where: matches)
        }
    }

    private static func evaluate(
        rules: [SmartPlaylistRule],
        combinator: SmartPlaylistCombinator,
        song: Song,
        stats: PlayStats,
        library: MusicLibrary
    ) -> Bool {
        switch combinator {
        case .and:
            return rules.allSatisfy {
                evaluate($0, song: song, stats: stats, library: library)
            }
        case .or:
            return rules.contains {
                evaluate($0, song: song, stats: stats, library: library)
            }
        }
    }

    private static func evaluate(
        _ rule: SmartPlaylistRule,
        song: Song,
        stats: PlayStats,
        library: MusicLibrary
    ) -> Bool {
        switch rule.field {
        case .title:
            return compareString(song.title, rule)
        case .artistName:
            return compareString(song.artistName ?? "", rule)
        case .albumTitle:
            return compareString(song.albumTitle ?? "", rule)
        case .genre:
            return compareString(song.genre ?? "", rule)
        case .fileFormat:
            return compareString(song.fileFormat.rawValue, rule)
        case .sourceID:
            return compareString(song.sourceID, rule)
        case .year:
            return compareInt(song.year, rule)
        case .fileSize:
            return compareInt(Int(song.fileSize), rule)
        case .bitRate:
            return compareInt(song.bitRate, rule)
        case .durationSec:
            return compareDouble(song.duration, rule)
        case .dateAdded:
            return compareDate(song.dateAdded, rule)
        case .playCount:
            let count = stats.countBySongID[song.id] ?? 0
            return compareInt(count, rule)
        case .lastPlayedAt:
            return compareDate(stats.lastPlayedBySongID[song.id], rule)
        case .isInPlaylist:
            // value 是 playlist.id; equals = 在该歌单里, notEquals = 不在
            let inSet = library.contains(songID: song.id, inPlaylist: rule.value)
            switch rule.op {
            case .equals: return inSet
            case .notEquals: return !inSet
            default: return false  // 其他 op 对 isInPlaylist 没意义
            }
        }
    }

    // MARK: - Comparators

    private static func compareString(_ value: String, _ rule: SmartPlaylistRule) -> Bool {
        let target = rule.value
        // 大小写不敏感, 配合用户随手输入。
        let v = value.lowercased()
        let t = target.lowercased()
        switch rule.op {
        case .equals: return v == t
        case .notEquals: return v != t
        case .contains: return v.contains(t)
        case .notContains: return !v.contains(t)
        default: return false
        }
    }

    private static func compareInt(_ value: Int?, _ rule: SmartPlaylistRule) -> Bool {
        let v = value ?? 0
        switch rule.op {
        case .equals:
            return Int(rule.value).map { $0 == v } ?? false
        case .notEquals:
            return Int(rule.value).map { $0 != v } ?? false
        case .greaterThan:
            return Int(rule.value).map { v > $0 } ?? false
        case .lessThan:
            return Int(rule.value).map { v < $0 } ?? false
        case .between:
            let parts = rule.value.split(separator: "|")
            guard parts.count == 2,
                  let lo = Int(parts[0]),
                  let hi = Int(parts[1]) else { return false }
            return v >= lo && v <= hi
        default: return false
        }
    }

    private static func compareDouble(_ value: Double, _ rule: SmartPlaylistRule) -> Bool {
        switch rule.op {
        case .equals:
            return Double(rule.value).map { abs($0 - value) < 0.0001 } ?? false
        case .notEquals:
            return Double(rule.value).map { abs($0 - value) >= 0.0001 } ?? false
        case .greaterThan:
            return Double(rule.value).map { value > $0 } ?? false
        case .lessThan:
            return Double(rule.value).map { value < $0 } ?? false
        case .between:
            let parts = rule.value.split(separator: "|")
            guard parts.count == 2,
                  let lo = Double(parts[0]),
                  let hi = Double(parts[1]) else { return false }
            return value >= lo && value <= hi
        default: return false
        }
    }

    private static func compareDate(_ value: Date?, _ rule: SmartPlaylistRule) -> Bool {
        // value 是 ISO8601 字符串。greaterThan = "晚于", lessThan = "早于"。
        // between 用 "iso1|iso2"。
        // 还支持相对天数: "days:7" 表示"最近 7 天内", greaterThan/equals/lessThan
        // 都把它解释成"now - days"作比较时间。这是最常用场景: 最近一周播过的。
        guard let value else { return false }

        if rule.value.hasPrefix("days:"),
           let threshold = parseDate(rule.value) {
            switch rule.op {
            case .equals, .greaterThan:
                return value >= threshold
            case .notEquals, .lessThan:
                return value < threshold
            default:
                return false
            }
        }

        let target = parseDate(rule.value)
        switch rule.op {
        case .equals:
            guard let t = target else { return false }
            // 同一天视为 equals (Date 精度对用户没意义)
            return Calendar.current.isDate(value, inSameDayAs: t)
        case .notEquals:
            guard let t = target else { return false }
            return !Calendar.current.isDate(value, inSameDayAs: t)
        case .greaterThan:
            return target.map { value > $0 } ?? false
        case .lessThan:
            return target.map { value < $0 } ?? false
        case .between:
            let parts = rule.value.split(separator: "|")
            guard parts.count == 2,
                  let lo = parseDate(String(parts[0])),
                  let hi = parseDate(String(parts[1])) else { return false }
            return value >= lo && value <= hi
        default: return false
        }
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseDate(_ text: String) -> Date? {
        if text.hasPrefix("days:"), let days = Int(text.dropFirst("days:".count)) {
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
        if let d = isoFormatter.date(from: text) { return d }
        // fallback: 常规 ISO8601 (无 fractional)
        let plain = ISO8601DateFormatter()
        return plain.date(from: text)
    }

    // MARK: - Sort + Limit

    private static func sortAndLimit(
        _ songs: [Song],
        smart: SmartPlaylist,
        history: PlayHistoryStore
    ) -> [Song] {
        let sorted: [Song]
        switch smart.sortField {
        case .title:
            sorted = songs.sorted { ($0.title) < ($1.title) }
        case .artistName:
            sorted = songs.sorted { ($0.artistName ?? "") < ($1.artistName ?? "") }
        case .albumTitle:
            sorted = songs.sorted { ($0.albumTitle ?? "") < ($1.albumTitle ?? "") }
        case .dateAdded:
            sorted = songs.sorted { $0.dateAdded < $1.dateAdded }
        case .duration:
            sorted = songs.sorted { $0.duration < $1.duration }
        case .lastPlayedAt:
            let lookup = PlayStats(history: history).lastPlayedBySongID
            sorted = songs.sorted { (lookup[$0.id] ?? .distantPast) < (lookup[$1.id] ?? .distantPast) }
        case .playCount:
            let lookup = PlayStats(history: history).countBySongID
            sorted = songs.sorted { (lookup[$0.id] ?? 0) < (lookup[$1.id] ?? 0) }
        case .random:
            // random 模式忽略 direction (用户既然要随机就别再纠结升降序)
            return Array(songs.shuffled().prefix(smart.limit ?? Int.max))
        }

        let directional = smart.sortDirection == .descending ? Array(sorted.reversed()) : sorted
        if let limit = smart.limit, directional.count > limit {
            return Array(directional.prefix(limit))
        }
        return directional
    }
}

// MARK: - Aggregated stats

/// 一次性把 PlayHistoryStore.entries 聚合成两个字典, 给规则评估和排序复用。
/// O(n) 一次扫描, library 几千首歌 / history 几千条都 ok。
@MainActor
private struct PlayStats {
    let countBySongID: [String: Int]
    let lastPlayedBySongID: [String: Date]

    init(history: PlayHistoryStore) {
        var count: [String: Int] = [:]
        var last: [String: Date] = [:]
        for entry in history.entries {
            count[entry.songID, default: 0] += 1
            if let prev = last[entry.songID] {
                if entry.playedAt > prev { last[entry.songID] = entry.playedAt }
            } else {
                last[entry.songID] = entry.playedAt
            }
        }
        self.countBySongID = count
        self.lastPlayedBySongID = last
    }
}
