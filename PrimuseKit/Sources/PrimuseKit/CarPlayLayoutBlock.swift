import Foundation

public enum CarPlayLayoutBlockKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcuts, playlists, albums, recentlyAdded, custom, radio, folders, ranking, siri
    /// 手机首页搬过来的三块:「为你推荐」的每日推荐、「开始听」的一点就播卡片、最近播放。
    case forYou, startListening, recentlyPlayed
    public var id: String { rawValue }
    public var titleKey: String {
        switch self {
        case .custom: "carplay_block_custom"
        case .radio: "radio_title"
        case .folders: "library_browse_folder"
        case .ranking: "carplay_listening_ranking"
        case .siri: "carplay_siri_suggestions"
        case .forYou: "home_for_you_title"
        case .startListening: "home_section_start_listening"
        case .recentlyPlayed: "recently_played"
        default: "carplay_section_" + rawValue
        }
    }
    /// 内容每天、每听一首都会重新生成:不能在编辑器里排序、增删成一组固定内容。
    public var keepsLiveContent: Bool {
        switch self {
        case .forYou, .startListening, .recentlyPlayed: true
        default: false
        }
    }
    public var symbol: String {
        switch self {
        case .shortcuts: "pin"
        case .playlists: "music.note.list"
        case .albums: "square.stack"
        case .recentlyAdded: "clock"
        case .custom: "square.grid.2x2"
        case .radio: "radio"
        case .folders: "folder.fill"
        case .ranking: "chart.bar.fill"
        case .siri: "waveform"
        case .forYou: "sparkles"
        case .startListening: "play.square.stack"
        case .recentlyPlayed: "clock.arrow.circlepath"
        }
    }
}

public struct CarPlayLayoutItem: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        case playlist, folder, album, song, radio, nowPlaying
        public var id: String { rawValue }
    }
    public var id: String
    public var kind: Kind
    public var targetID: String
    public var title: String

    public init(id: String = UUID().uuidString, kind: Kind, targetID: String, title: String) {
        self.id = id
        self.kind = kind
        self.targetID = targetID
        self.title = title
    }

    public var folderID: LibraryFolderNodeID? {
        guard kind == .folder else { return nil }
        return HomeFolderPinStorage.decode(targetID).first
    }

    public var dragValue: String {
        guard let data = try? JSONEncoder().encode(self) else { return "" }
        return "carplay-content:" + data.base64EncodedString()
    }

    public static func fromDragValue(_ value: String) -> Self? {
        let prefix = "carplay-content:"
        guard value.hasPrefix(prefix), value.utf8.count < 16_384,
              let data = Data(base64Encoded: String(value.dropFirst(prefix.count))),
              let item = try? JSONDecoder().decode(Self.self, from: data),
              !item.targetID.isEmpty, item.title.count <= 512 else { return nil }
        return item
    }
}

public struct CarPlayLayoutBlock: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var kind: CarPlayLayoutBlockKind
    public var title = ""
    public var style: CarPlayBrowseStyle
    public var columns = 3
    public var rowsPerPage = 2
    public var itemLimit = 6
    public var showsTitle = true
    public var isVisible = true
    public var playsImmediately = true
    public var items: [CarPlayLayoutItem] = []
    public var usesCustomContent = false

    public init(id: String = UUID().uuidString, kind: CarPlayLayoutBlockKind, style: CarPlayBrowseStyle = .covers) {
        self.id = id
        self.kind = kind
        self.style = style
    }

    public var normalized: Self {
        var result = self
        result.columns = min(6, max(2, columns))
        result.rowsPerPage = min(4, max(1, rowsPerPage))
        result.itemLimit = min(60, max(1, itemLimit))
        result.title = String(title.prefix(80))
        var seen = Set<String>()
        result.items = Array(items.filter { !$0.targetID.isEmpty && seen.insert($0.id).inserted }.prefix(60))
        return result
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, style, columns, rowsPerPage, itemLimit, showsTitle, isVisible, playsImmediately, items, usesCustomContent
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        kind = try values.decode(CarPlayLayoutBlockKind.self, forKey: .kind)
        style = (try? values.decode(CarPlayBrowseStyle.self, forKey: .style)) ?? .covers
        title = (try? values.decode(String.self, forKey: .title)) ?? ""
        columns = (try? values.decode(Int.self, forKey: .columns)) ?? 3
        rowsPerPage = (try? values.decode(Int.self, forKey: .rowsPerPage)) ?? 2
        itemLimit = (try? values.decode(Int.self, forKey: .itemLimit)) ?? 6
        showsTitle = (try? values.decode(Bool.self, forKey: .showsTitle)) ?? true
        isVisible = (try? values.decode(Bool.self, forKey: .isVisible)) ?? true
        playsImmediately = (try? values.decode(Bool.self, forKey: .playsImmediately)) ?? true
        items = (try? values.decode([CarPlayLayoutItem].self, forKey: .items)) ?? []
        usesCustomContent = (try? values.decode(Bool.self, forKey: .usesCustomContent)) ?? (kind == .custom)
    }
}

public struct CarPlaySavedLayout: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var configuration: CarPlayLayoutConfiguration

    public init(id: String = UUID().uuidString, name: String, configuration: CarPlayLayoutConfiguration) {
        self.id = id
        self.name = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        self.configuration = configuration
    }
}

public struct CarPlayLayoutHistory {
    private var previous: [CarPlayLayoutConfiguration] = []
    private var following: [CarPlayLayoutConfiguration] = []
    public init() {}
    public var canUndo: Bool { !previous.isEmpty }
    public var canRedo: Bool { !following.isEmpty }

    public mutating func record(_ old: CarPlayLayoutConfiguration, replacing new: CarPlayLayoutConfiguration) {
        guard old != new else { return }
        previous.append(old)
        previous = Array(previous.suffix(30))
        following.removeAll()
    }

    public mutating func undo(_ current: CarPlayLayoutConfiguration) -> CarPlayLayoutConfiguration? {
        guard let result = previous.popLast() else { return nil }
        following.append(current)
        return result
    }

    public mutating func redo(_ current: CarPlayLayoutConfiguration) -> CarPlayLayoutConfiguration? {
        guard let result = following.popLast() else { return nil }
        previous.append(current)
        return result
    }
}
