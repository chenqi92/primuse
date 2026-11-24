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
        /// Subscribed podcasts: episodes in progress, the latest ones, then the shows.
        case podcast

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
            case .podcast: "listening_space_podcast"
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
            case .podcast: "antenna.radiowaves.left.and.right"
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

public enum CarPlayLyricsPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case followPhone, off, subtitle, title
    public var id: String { rawValue }
    public var titleKey: String { "carplay_lyrics_" + rawValue }

    public func isEnabled(phoneEnabled: Bool) -> Bool {
        switch self {
        case .followPhone: phoneEnabled
        case .off: false
        case .subtitle, .title: true
        }
    }
}

public enum CarPlayTopRightAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case queue, album, audioInfo, more, hidden
    public var id: String { rawValue }
    public var titleKey: String {
        switch self {
        case .queue: "carplay_up_next"
        case .more: "more"
        default: "carplay_top_" + rawValue
        }
    }
}

public enum CarPlayNowPlayingAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case shuffle, repeatMode, like, audioQuality, queue, album, playbackRate, skipBackward, skipForward
    case audioFormat, audioBitRate, audioResolution, songActions, artist
    /// 有声内容的减一档、加一档(#423),和中间那颗速度键排成 Apple Books 那样的「− 1.25× +」。
    case slowerPlaybackRate, fasterPlaybackRate

    public var isAudioInfo: Bool {
        [.audioQuality, .audioFormat, .audioBitRate, .audioResolution].contains(self)
    }

    /// 调速度的三颗键:当前内容不能变速时一起不出现。
    public var isPlaybackRateControl: Bool {
        [.playbackRate, .slowerPlaybackRate, .fasterPlaybackRate].contains(self)
    }

    public var id: String { rawValue }
    public var titleKey: String {
        switch self {
        case .shuffle: "shuffle"
        case .repeatMode: "repeat"
        case .like: "player_controls_action_like"
        case .audioQuality: "carplay_audio_summary"
        case .audioFormat: "format_label"
        case .audioBitRate: "songs_column_bitrate"
        case .audioResolution: "carplay_audio_resolution"
        case .queue: "carplay_up_next"
        case .album: "carplay_albums_title"
        case .artist: "go_to_artist"
        case .songActions: "carplay_song_actions"
        case .playbackRate: "playback_rate"
        case .slowerPlaybackRate: "transcript_reader_speed_slower"
        case .fasterPlaybackRate: "transcript_reader_speed_faster"
        case .skipBackward: "spoken_word_skip_backward"
        case .skipForward: "spoken_word_skip_forward"
        }
    }
    public var symbol: String {
        switch self {
        case .shuffle: "shuffle"
        case .repeatMode: "repeat"
        case .like: "heart"
        case .audioQuality, .audioFormat, .audioBitRate, .audioResolution: "waveform"
        case .queue: "list.bullet"
        case .album: "square.stack"
        case .artist: "music.mic"
        case .songActions: "ellipsis.circle"
        case .playbackRate: "speedometer"
        case .slowerPlaybackRate: "minus.circle"
        case .fasterPlaybackRate: "plus.circle"
        case .skipBackward: "gobackward"
        case .skipForward: "goforward"
        }
    }

    /// 前五个就是默认按钮。有声内容默认「快退 − 速度 + 快进」(#423):听书时系统那两个切换键
    /// 默认是上一章、下一章,车上最常用的快退快进和调速度都放在这一排;喜欢、音质留在可选列表里。
    public static func available(isSpokenWord: Bool) -> [Self] {
        isSpokenWord
            ? [.skipBackward, .slowerPlaybackRate, .playbackRate, .fasterPlaybackRate, .skipForward,
               .like, .audioQuality, .queue, .audioFormat, .audioBitRate, .audioResolution]
            : [.shuffle, .repeatMode, .like, .audioQuality, .audioBitRate, .queue, .songActions, .album, .artist, .audioFormat, .audioResolution]
    }

    public static func defaults(isSpokenWord: Bool) -> [Self] {
        Array(available(isSpokenWord: isSpokenWord).prefix(CarPlayLayoutConfiguration.maximumNowPlayingButtonCount))
    }
}

public struct CarPlayLayoutConfiguration: Codable, Equatable, Sendable {
    public static let storageKey = "primuse.carplay.layout.v1"
    public static let maximumShortcutCount = 12
    public static let maximumBlockCount = 12
    public static let maximumSavedTabCount = 12
    public static let maximumNowPlayingButtonCount = 5

    public var browseStyle: CarPlayBrowseStyle = .list
    public var sectionOrder: [CarPlayHomeSection] = CarPlayHomeSection.allCases
    public var hiddenSections: Set<CarPlayHomeSection> = [.albums]
    public var playsCollectionsDirectly = true
    public var opensNowPlayingOnConnect = false
    public var opensNowPlayingAfterSelection = true
    public var minimalNowPlaying = false
    public var lyricsPosition: CarPlayLyricsPosition = .followPhone
    public var topRightAction: CarPlayTopRightAction = .queue
    public var customNowPlayingButtons: [CarPlayNowPlayingAction]?
    public var customSpokenWordButtons: [CarPlayNowPlayingAction]?
    public var pinnedPlaylistIDs: [String] = []
    public var pinnedFolders = "[]"
    public var customBlocks: [CarPlayLayoutBlock]?
    public var visualStyle: CarPlayVisualStyle = .list
    public var customTabs: [CarPlayMainTab]?
    public var siriPresentation: CarPlaySiriPresentation = .button

    public init() {}

    public static var recommended: Self {
        var configuration = Self()
        configuration.visualStyle = .wall
        configuration.browseStyle = .covers
        configuration.blocks = [CarPlayLayoutBlockKind.shortcuts, .recentlyPlayed, .forYou, .playlists].map { kind in
            var block = CarPlayLayoutBlock(id: "recommended." + kind.rawValue, kind: kind,
                                          style: kind == .shortcuts ? .list : .covers)
            block.columns = 2
            block.itemLimit = kind == .shortcuts ? 4 : 6
            return block
        }
        return configuration
    }

    public func nowPlayingButtons(isSpokenWord: Bool) -> [CarPlayNowPlayingAction] {
        let saved = isSpokenWord ? customSpokenWordButtons : customNowPlayingButtons
        let available = CarPlayNowPlayingAction.available(isSpokenWord: isSpokenWord)
        return Array(Self.unique(saved ?? CarPlayNowPlayingAction.defaults(isSpokenWord: isSpokenWord))
            .filter { available.contains($0) }.prefix(Self.maximumNowPlayingButtonCount))
    }

    public mutating func setNowPlayingButtons(_ buttons: [CarPlayNowPlayingAction], isSpokenWord: Bool) {
        if isSpokenWord { customSpokenWordButtons = buttons }
        else { customNowPlayingButtons = buttons }
    }

    public func visibleNowPlayingButtons(isSpokenWord: Bool, isLiveRadio: Bool, supportsPlaybackRate: Bool) -> [CarPlayNowPlayingAction] {
        guard !minimalNowPlaying, !isLiveRadio else { return [] }
        return nowPlayingButtons(isSpokenWord: isSpokenWord).filter {
            (!$0.isPlaybackRateControl || supportsPlaybackRate) && ($0 != .queue || topRightAction != .queue)
        }
    }

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
        let musicButtons = customNowPlayingButtons
        let spokenButtons = customSpokenWordButtons
        self = Self()
        customTabs = tabs
        siriPresentation = siri
        customNowPlayingButtons = musicButtons
        customSpokenWordButtons = spokenButtons
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
        presentation.customNowPlayingButtons = nil
        presentation.customSpokenWordButtons = nil
        return CarPlayLayoutPreset.allCases.first { preset in
            var candidate = Self()
            candidate.apply(preset)
            return candidate == presentation
        }
    }

    public static func load(from defaults: UserDefaults) -> Self {
        guard let data = defaults.data(forKey: storageKey),
              let value = try? JSONDecoder().decode(Self.self, from: data) else { return .recommended }
        return value
    }

    public func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    private enum CodingKeys: String, CodingKey {
        case browseStyle, sectionOrder, hiddenSections, playsCollectionsDirectly
        case opensNowPlayingOnConnect, opensNowPlayingAfterSelection, minimalNowPlaying
        case customNowPlayingButtons, customSpokenWordButtons
        case lyricsPosition, topRightAction
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
        lyricsPosition = (try? values.decode(CarPlayLyricsPosition.self, forKey: .lyricsPosition)) ?? lyricsPosition
        topRightAction = (try? values.decode(CarPlayTopRightAction.self, forKey: .topRightAction)) ?? topRightAction
        if let actions = try? values.decode([String].self, forKey: .customNowPlayingButtons) {
            customNowPlayingButtons = actions.compactMap(CarPlayNowPlayingAction.init(rawValue:))
        }
        if let actions = try? values.decode([String].self, forKey: .customSpokenWordButtons) {
            customSpokenWordButtons = actions.compactMap(CarPlayNowPlayingAction.init(rawValue:))
        }
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

/// Pure presentation and bitrate-selection policy for the CarPlay Now Playing
/// audio-quality modal popup (`CPAlertTemplate`).
public enum CarPlayAudioQualityPopupPolicy {
    public struct Labels: Sendable, Equatable {
        public let original: String
        public let kbps320: String
        public let kbps256: String
        public let kbps192: String
        public let kbps128: String
        public let ok: String
        public let originalFilePrefix: String
        public let outputPrefix: String
        public let fallbackTitle: String

        public init(
            original: String,
            kbps320: String,
            kbps256: String,
            kbps192: String,
            kbps128: String,
            ok: String,
            originalFilePrefix: String,
            outputPrefix: String,
            fallbackTitle: String
        ) {
            self.original = original
            self.kbps320 = kbps320
            self.kbps256 = kbps256
            self.kbps192 = kbps192
            self.kbps128 = kbps128
            self.ok = ok
            self.originalFilePrefix = originalFilePrefix
            self.outputPrefix = outputPrefix
            self.fallbackTitle = fallbackTitle
        }

        public func title(for preference: StreamQualityPreference) -> String {
            switch preference {
            case .original: original
            case .kbps320: kbps320
            case .kbps256: kbps256
            case .kbps192: kbps192
            case .kbps128: kbps128
            }
        }
    }

    public enum ActionKind: Sendable, Equatable {
        case selectQuality(StreamQualityPreference)
        case dismiss
    }

    public struct Action: Sendable, Equatable {
        public let title: String
        public let kind: ActionKind
        public let isSelected: Bool
        public let isCancelStyle: Bool

        public init(title: String, kind: ActionKind, isSelected: Bool, isCancelStyle: Bool) {
            self.title = title
            self.kind = kind
            self.isSelected = isSelected
            self.isCancelStyle = isCancelStyle
        }
    }

    public struct Presentation: Sendable, Equatable {
        public let titleVariants: [String]
        public let actions: [Action]
    }

    public static func presentation(
        quality: CarPlayAudioQualityText,
        outputSampleRateText: String?,
        supportsBitrateSwitching: Bool,
        activePreference: StreamQualityPreference,
        maximumActionCount: Int,
        labels: Labels
    ) -> Presentation {
        let titles = titleVariants(
            quality: quality,
            outputSampleRateText: outputSampleRateText,
            labels: labels
        )
        let limit = max(1, maximumActionCount)
        let actions: [Action]
        if supportsBitrateSwitching, limit >= 2 {
            let presets = horizontalPresets(activePreference: activePreference, limit: limit)
            actions = presets.map { preset in
                let selected = preset == activePreference
                let baseTitle = labels.title(for: preset)
                return Action(
                    title: selected ? "✓ \(baseTitle)" : baseTitle,
                    kind: selected ? .dismiss : .selectQuality(preset),
                    isSelected: selected,
                    isCancelStyle: selected
                )
            }
        } else {
            actions = [
                Action(title: labels.ok, kind: .dismiss, isSelected: false, isCancelStyle: true)
            ]
        }
        return Presentation(titleVariants: titles, actions: actions)
    }

    public static func horizontalPresets(
        activePreference: StreamQualityPreference,
        limit: Int
    ) -> [StreamQualityPreference] {
        switch max(1, limit) {
        case 1:
            return [activePreference]
        case 2:
            return activePreference == .original ? [.original, .kbps320] : [.original, activePreference]
        case 3:
            let middle: StreamQualityPreference
            switch activePreference {
            case .kbps256, .kbps192:
                middle = activePreference
            case .original, .kbps320, .kbps128:
                middle = .kbps320
            }
            return [.original, middle, .kbps128]
        case 4:
            let third: StreamQualityPreference = activePreference == .kbps192 ? .kbps192 : .kbps256
            return [.original, .kbps320, third, .kbps128]
        default:
            return StreamQualityPreference.allCases
        }
    }

    private static func titleVariants(
        quality: CarPlayAudioQualityText,
        outputSampleRateText: String?,
        labels: Labels
    ) -> [String] {
        let details = quality.details.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = quality.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceDetails = quality.sourceDetails?.trimmingCharacters(in: .whitespacesAndNewlines)
        let output = outputSampleRateText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let primary = details.isEmpty ? summary : details

        var candidates: [String] = []
        if let sourceDetails, !sourceDetails.isEmpty {
            if let output, !output.isEmpty {
                candidates.append("\(primary) · \(labels.outputPrefix) \(output)\n\(labels.originalFilePrefix): \(sourceDetails)")
            }
            candidates.append("\(primary)\n\(labels.originalFilePrefix): \(sourceDetails)")
        } else if let output, !output.isEmpty {
            candidates.append("\(primary)\n\(labels.outputPrefix): \(output)")
        }
        candidates.append(primary)
        candidates.append(summary)

        var result: [String] = []
        var seen = Set<String>()
        for item in candidates where !item.isEmpty {
            if seen.insert(item).inserted {
                result.append(item)
            }
        }
        if result.isEmpty {
            result.append(labels.fallbackTitle)
        }
        return result
    }
}
