import Foundation

// MARK: - Field / Operator / Combinator / Sort

/// 智能歌单可用的过滤字段。命名跟 Song / playEvents 表的列对齐 ──
/// engine 把字段转成 SQL 时直接用 rawValue 拼列名 (注意防注入由 enum
/// 限制取值实现)。
public enum SmartPlaylistField: String, Codable, CaseIterable, Sendable {
    case title
    case artistName
    case albumTitle
    case genre
    case year
    case fileFormat
    case dateAdded
    case durationSec       // 来源: songs.duration
    case fileSize
    case bitRate
    case sourceID
    case playCount         // 来源: PlayHistoryStore (本地聚合)
    case lastPlayedAt      // 来源: PlayHistoryStore
    case isInPlaylist      // 来源: playlistSongs join (value 是 playlist.id)

    /// 字段是否能在 GRDB SQL 里直接 WHERE。playCount / lastPlayedAt /
    /// isInPlaylist 不在 songs 表上, engine 会先 SQL 出候选, 再用 in-memory
    /// 字典 / join 后处理过滤。
    public var requiresPostFilter: Bool {
        switch self {
        case .playCount, .lastPlayedAt, .isInPlaylist: return true
        default: return false
        }
    }

    /// 字段 storage 类型 ── 决定 SQL 类型 cast 与 UI 编辑器形态。
    public enum ValueKind: Sendable {
        case text, integer, double, date
    }

    public var valueKind: ValueKind {
        switch self {
        case .title, .artistName, .albumTitle, .genre, .fileFormat, .sourceID, .isInPlaylist:
            return .text
        case .year, .fileSize, .bitRate, .playCount:
            return .integer
        case .durationSec:
            return .double
        case .dateAdded, .lastPlayedAt:
            return .date
        }
    }
}

public enum SmartPlaylistOperator: String, Codable, CaseIterable, Sendable {
    case equals
    case notEquals
    case contains          // 仅 text
    case notContains       // 仅 text
    case greaterThan
    case lessThan
    case between           // value 是 "a|b" 形式

    public func supports(_ kind: SmartPlaylistField.ValueKind) -> Bool {
        switch self {
        case .equals, .notEquals: return true
        case .contains, .notContains: return kind == .text
        case .greaterThan, .lessThan, .between:
            return kind == .integer || kind == .double || kind == .date
        }
    }
}

/// 多条规则之间用 AND 还是 OR 串。复杂嵌套 (AND 内嵌 OR) 不在 v1 范围内 ──
/// 用户能用 OR 多条覆盖 90% 场景, 后续要再加。
public enum SmartPlaylistCombinator: String, Codable, Sendable {
    case and
    case or
}

public enum SmartPlaylistSortField: String, Codable, CaseIterable, Sendable {
    case title
    case artistName
    case albumTitle
    case dateAdded
    case lastPlayedAt
    case playCount
    case duration
    case random            // 每次 query 重排
}

public enum SmartPlaylistSortDirection: String, Codable, Sendable {
    case ascending
    case descending
}

// MARK: - Rule

public struct SmartPlaylistRule: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var field: SmartPlaylistField
    public var op: SmartPlaylistOperator
    /// 字符串化的值 ── integer / double / date 由 engine 按 field.valueKind
    /// 解析。这样 rules JSON 可以稳定 round-trip 跨设备 (Swift Date 编码差异
    /// 导致直接 Codable Any 不可行)。
    /// between 用 "min|max" 编码。
    public var value: String

    public init(
        id: String = UUID().uuidString,
        field: SmartPlaylistField,
        op: SmartPlaylistOperator,
        value: String
    ) {
        self.id = id
        self.field = field
        self.op = op
        self.value = value
    }
}

// MARK: - Smart Playlist

public struct SmartPlaylist: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var rules: [SmartPlaylistRule]
    public var combinator: SmartPlaylistCombinator
    /// 匹配上限 (nil = 不限)。命中超过此数时按 sortField 截断。
    public var limit: Int?
    public var sortField: SmartPlaylistSortField
    public var sortDirection: SmartPlaylistSortDirection
    public var createdAt: Date
    public var updatedAt: Date
    /// soft-delete (跟普通 Playlist 一致, 给 CloudKit 收敛留窗口)。
    public var isDeleted: Bool
    public var deletedAt: Date?

    public init(
        id: String = UUID().uuidString,
        name: String,
        rules: [SmartPlaylistRule] = [],
        combinator: SmartPlaylistCombinator = .and,
        limit: Int? = nil,
        sortField: SmartPlaylistSortField = .dateAdded,
        sortDirection: SmartPlaylistSortDirection = .descending,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        isDeleted: Bool = false,
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.rules = rules
        self.combinator = combinator
        self.limit = limit
        self.sortField = sortField
        self.sortDirection = sortDirection
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.isDeleted = isDeleted
        self.deletedAt = deletedAt
    }
}

// MARK: - Codable
//
// 持久化跟随 Playlist 的现有路径 ── MusicLibrary.Snapshot 里序列化到
// JSON, 不走 GRDB。这样跟 playlist 一致, CloudKit 同步逻辑也对得上。
