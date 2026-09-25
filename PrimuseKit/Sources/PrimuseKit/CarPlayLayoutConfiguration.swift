import Foundation

public enum CarPlayLayoutPreset: String, CaseIterable, Identifiable, Sendable {
    case quickPlay, artwork, focus
    public var id: String { rawValue }
    public var titleKey: String { "carplay_preset_" + rawValue }
}

public enum CarPlayBrowseStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case list, covers, cards, capsules
    public var id: String { rawValue }
    public var titleKey: String { "carplay_style_" + rawValue }
}

public enum CarPlayVisualStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case list, wall, capsules
    public var id: String { rawValue }
    public var titleKey: String { "carplay_visual_" + rawValue }
    public var subtitleKey: String { "carplay_visual_" + rawValue + "_detail" }
}

public enum CarPlayHomeSection: String, Codable, CaseIterable, Identifiable, Sendable {
    case shortcuts, playlists, albums, recentlyAdded
    public var id: String { rawValue }
    public var titleKey: String { "carplay_section_" + rawValue }
}

public struct CarPlayMainTab: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case home, library, radio, playlists, songs, albums, artists, folders, search, collection
        /// Books and other spoken word: in progress first, never shuffled.
        case spokenWord

        public var titleKey: String {
            switch self {
            case .home: "carplay_home_title"
            case .library: "library_title"
            case .radio: "radio_title"
            case .playlists, .songs, .albums, .artists: "carplay_" + rawValue + "_title"
            case .folders: "library_browse_folder"
            case .search: "search_title"
            case .collection: "carplay_content_sources"
            case .spokenWord: "listening_space_spoken_word"
            }
        }

        public var symbol: String {
            switch self {
            case .home: "house"
            case .library: "square.stack"
            case .radio: "radio"
            case .playlists, .collection: "music.note.list"
            case .songs: "music.note"
            case .albums: "square.stack"
            case .artists: "music.mic"
            case .folders: "folder"
            case .search: "magnifyingglass"
            case .spokenWord: "books.vertical"
            }
        }
    }

    public var id: String
    public var kind: Kind
    public var title: String
    public var isVisible: Bool
    public var content: CarPlayLayoutItem?

    public init(id: String = UUID().uuidString, kind: Kind, title: String = "", isVisible: Bool = true, content: CarPlayLayoutItem? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.isVisible = isVisible
        self.content = content
    }

    public var symbol: String {
        guard kind == .collection else { return kind.symbol }
        switch content?.kind {
        case .folder: return "folder"
        case .album: return "square.stack"
        default: return "music.note.list"
        }
    }

    public var isValid: Bool {
        guard !id.isEmpty else { return false }
        guard kind == .collection else { return true }
        guard let content, !content.targetID.isEmpty else { return false }
        return content.kind == .playlist || content.kind == .album || (content.kind == .folder && content.folderID != nil)
    }

    public static var defaults: [Self] {
        [Kind.home, .library, .radio, .playlists].map { Self(id: "tab." + $0.rawValue, kind: $0) }
    }
}

public enum CarPlaySiriPresentation: String, Codable, Sendable {
    case button, row
}

public struct CarPlayLayoutConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.carplay.layout.v1"
    public static let maximumShortcutCount = 12
    public static let maximumBlockCount = 12
    public static let maximumSavedTabCount = 12

    public var browseStyle: CarPlayBrowseStyle = .list
    public var sectionOrder: [CarPlayHomeSection] = CarPlayHomeSection.allCases
    public var hiddenSections: Set<CarPlayHomeSection> = [.albums]
    public var playsCollectionsDirectly = true
    public var opensNowPlayingOnConnect = false
    public var opensNowPlayingAfterSelection = true
    public var minimalNowPlaying = false
    public var pinnedPlaylistIDs: [String] = []
    public var pinnedFolders = "[]"
    public var customBlocks: [CarPlayLayoutBlock]?
    public var visualStyle: CarPlayVisualStyle = .list
    public var customTabs: [CarPlayMainTab]?
    public var siriPresentation: CarPlaySiriPresentation = .button

    public init() {}

    public var folderIDs: [LibraryFolderNodeID] {
        get { HomeFolderPinStorage.decode(pinnedFolders) }
        set { pinnedFolders = HomeFolderPinStorage.encode(newValue) }
    }

    public var canAddShortcut: Bool {
        pinnedPlaylistIDs.count + folderIDs.count < Self.maximumShortcutCount
    }

    public var showsSiri: Bool { blocks.first { $0.kind == .siri }?.isVisible ?? false }

    public var tabs: [CarPlayMainTab] {
        get {
            var seen = Set<String>()
            let valid = (customTabs ?? CarPlayMainTab.defaults).filter { $0.isValid && seen.insert($0.id).inserted }
            return Array(valid.prefix(Self.maximumSavedTabCount))
        }
        set { customTabs = newValue }
    }

    public func visibleTabs(maximumCount: Int) -> [CarPlayMainTab] {
        let visible = tabs.filter(\.isVisible)
        return Array((visible.isEmpty ? [CarPlayMainTab.defaults[0]] : visible).prefix(max(1, maximumCount)))
    }

    @discardableResult
    public mutating func setTabVisible(_ id: String, visible: Bool, maximumCount: Int) -> Bool {
        var updated = tabs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return false }
        guard updated[index].isVisible != visible else { return true }
        let count = updated.filter(\.isVisible).count
        guard visible ? count < maximumCount : count > 1 else { return false }
        updated[index].isVisible = visible
        tabs = updated
        return true
    }

    @discardableResult
    public mutating func moveTab(_ id: String, before destination: String?) -> Bool {
        var updated = tabs
        guard id != destination, let index = updated.firstIndex(where: { $0.id == id }),
              destination == nil || updated.contains(where: { $0.id == destination }) else { return false }
        let tab = updated.remove(at: index)
        let target = destination.flatMap { id in updated.firstIndex { $0.id == id } } ?? updated.count
        updated.insert(tab, at: target)
        tabs = updated
        return true
    }

    public var visibleSections: [CarPlayHomeSection] {
        Self.unique(sectionOrder + CarPlayHomeSection.allCases).filter { !hiddenSections.contains($0) }
    }

    public var blocks: [CarPlayLayoutBlock] {
        get {
            if let customBlocks {
                var seen = Set<String>()
                return Array(customBlocks.filter { seen.insert($0.id).inserted }.prefix(Self.maximumBlockCount)).map(\.normalized)
            }
            return visibleSections.map { section in
                var block = CarPlayLayoutBlock(id: "legacy." + section.rawValue,
                                               kind: CarPlayLayoutBlockKind(rawValue: section.rawValue) ?? .custom,
                                               style: browseStyle)
                block.playsImmediately = section == .shortcuts || playsCollectionsDirectly
                block.itemLimit = section == .shortcuts ? 24 : (section == .recentlyAdded ? 8 : 6)
                return block
            }
        }
        set { customBlocks = newValue.map(\.normalized) }
    }

    @discardableResult
    public mutating func moveBlock(_ id: String, before destination: String?) -> Bool {
        guard id != destination else { return false }
        var updated = blocks
        guard let index = updated.firstIndex(where: { $0.id == id }),
              destination == nil || updated.contains(where: { $0.id == destination }) else { return false }
        let block = updated.remove(at: index)
        let target = destination.flatMap { destination in updated.firstIndex { $0.id == destination } } ?? updated.count
        updated.insert(block, at: target)
        blocks = updated
        return true
    }

    @discardableResult
    public mutating func moveItem(_ id: String, from sourceID: String, to destinationID: String, before itemID: String? = nil) -> Bool {
        guard id != itemID else { return false }
        var updated = blocks
        guard let source = updated.firstIndex(where: { $0.id == sourceID }),
              let destination = updated.firstIndex(where: { $0.id == destinationID }),
              (updated[destination].kind == .custom || updated[destination].usesCustomContent),
              source == destination || (updated[destination].items.count < 60 && !updated[destination].items.contains { $0.id == id }),
              let index = updated[source].items.firstIndex(where: { $0.id == id }),
              itemID == nil || updated[destination].items.contains(where: { $0.id == itemID }) else { return false }
        let item = updated[source].items.remove(at: index)
        let target = itemID.flatMap { id in updated[destination].items.firstIndex { $0.id == id } }
            ?? updated[destination].items.count
        updated[destination].items.insert(item, at: target)
        updated[destination].itemLimit = max(updated[destination].itemLimit, updated[destination].items.count)
        blocks = updated
        return true
    }

    public mutating func apply(_ preset: CarPlayLayoutPreset) {
        let playlists = pinnedPlaylistIDs
        let folders = pinnedFolders
        let collections = blocks.filter { $0.kind == .custom || $0.usesCustomContent }
        let tabs = customTabs
        let siri = siriPresentation
        self = Self()
        customTabs = tabs
        siriPresentation = siri
        pinnedPlaylistIDs = playlists
        pinnedFolders = folders
        switch preset {
        case .quickPlay:
            break
        case .artwork:
            visualStyle = .wall
            browseStyle = .cards
            hiddenSections = []
            playsCollectionsDirectly = false
        case .focus:
            hiddenSections = [.playlists, .albums, .recentlyAdded]
            opensNowPlayingOnConnect = true
            minimalNowPlaying = true
        }
        if !collections.isEmpty {
            blocks = collections.map { block in
                var updated = block
                updated.style = browseStyle
                return updated
            } + blocks
        }
    }

    public mutating func applyVisualStyle(_ style: CarPlayVisualStyle) {
        visualStyle = style
        browseStyle = style == .list ? .list : (style == .capsules ? .capsules : .covers)
        blocks = blocks.map { block in
            var result = block
            result.style = browseStyle
            result.columns = style == .wall ? 3 : 2
            result.rowsPerPage = style == .capsules ? 3 : 2
            return result
        }
    }

    public var matchingPreset: CarPlayLayoutPreset? {
        var presentation = self
        presentation.pinnedPlaylistIDs = []
        presentation.pinnedFolders = "[]"
        presentation.customTabs = nil
        presentation.siriPresentation = .button
        return CarPlayLayoutPreset.allCases.first { preset in
            var candidate = Self()
            candidate.apply(preset)
            return candidate == presentation
        }
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        return value
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case browseStyle, sectionOrder, hiddenSections, playsCollectionsDirectly
        case opensNowPlayingOnConnect, opensNowPlayingAfterSelection, minimalNowPlaying
        case pinnedPlaylistIDs, pinnedFolders, customBlocks, visualStyle, customTabs, siriPresentation
    }

    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        browseStyle = (try? values.decode(CarPlayBrowseStyle.self, forKey: .browseStyle)) ?? browseStyle
        visualStyle = (try? values.decode(CarPlayVisualStyle.self, forKey: .visualStyle)) ?? (browseStyle == .list ? .list : .wall)
        if (try? values.decode(String.self, forKey: .visualStyle)) == "split" {
            visualStyle = .list
            browseStyle = .list
        }
        siriPresentation = (try? values.decode(CarPlaySiriPresentation.self, forKey: .siriPresentation)) ?? .button
        if let records = try? values.decode([TabRecord].self, forKey: .customTabs) {
            customTabs = records.compactMap(\.value)
        }
        if let order = try? values.decode([String].self, forKey: .sectionOrder) {
            sectionOrder = Self.unique(order.compactMap(CarPlayHomeSection.init(rawValue:)) + CarPlayHomeSection.allCases)
        }
        if let hidden = try? values.decode([String].self, forKey: .hiddenSections) {
            hiddenSections = Set(hidden.compactMap(CarPlayHomeSection.init(rawValue:)))
        }
        playsCollectionsDirectly = (try? values.decode(Bool.self, forKey: .playsCollectionsDirectly)) ?? playsCollectionsDirectly
        opensNowPlayingOnConnect = (try? values.decode(Bool.self, forKey: .opensNowPlayingOnConnect)) ?? opensNowPlayingOnConnect
        opensNowPlayingAfterSelection = (try? values.decode(Bool.self, forKey: .opensNowPlayingAfterSelection)) ?? opensNowPlayingAfterSelection
        minimalNowPlaying = (try? values.decode(Bool.self, forKey: .minimalNowPlaying)) ?? minimalNowPlaying
        pinnedPlaylistIDs = Self.unique((try? values.decode([String].self, forKey: .pinnedPlaylistIDs)) ?? [])
        pinnedFolders = (try? values.decode(String.self, forKey: .pinnedFolders)) ?? pinnedFolders
        if let records = try? values.decode([BlockRecord].self, forKey: .customBlocks) {
            customBlocks = records.compactMap(\.value)
        }
    }

    private struct BlockRecord: Decodable {
        let value: CarPlayLayoutBlock?
        init(from decoder: Decoder) throws { value = try? CarPlayLayoutBlock(from: decoder) }
    }

    private struct TabRecord: Decodable {
        let value: CarPlayMainTab?
        init(from decoder: Decoder) throws { value = try? CarPlayMainTab(from: decoder) }
    }

    private static func unique<T: Hashable>(_ values: [T]) -> [T] {
        var seen = Set<T>()
        return values.filter { seen.insert($0).inserted }
    }
}
