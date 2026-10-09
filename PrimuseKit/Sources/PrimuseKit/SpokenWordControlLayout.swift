import Foundation

/// 有声内容播放页分两种:有声书和播客。各有一份按钮配置。
public enum SpokenWordPlayerKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case audiobook
    case podcast

    public var id: String { rawValue }
}

/// 有声书、播客播放页上那一排功能块。rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum SpokenWordControlTile: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case speed
    case sleepTimer
    case bookmark
    /// 书是「目录」;播客打开的是节目说明(有章节时还有章节、书签)。
    case contents
    /// 播客后面排着的单集。书没有队列可看,不出这一块。
    case upNext

    public var id: String { rawValue }

    public func isAvailable(for kind: SpokenWordPlayerKind) -> Bool {
        self != .upNext || kind == .podcast
    }
}

/// 有声书或播客播放页的按钮:功能块的顺序与显隐,以及歌名旁的喜欢、文字稿键和播放键两侧的
/// 上一章 / 下一章。整份存成一个 JSON 字符串,没改过(或恢复默认)时存空串。
public struct SpokenWordControlLayout: Equatable, Sendable {
    public let kind: SpokenWordPlayerKind
    /// 这一种播放页能出现的全部功能块,按用户排的顺序(含隐藏的)。
    public private(set) var order: [SpokenWordControlTile]
    public private(set) var hidden: Set<SpokenWordControlTile>
    public private(set) var showsLike: Bool
    public private(set) var showsTranscriptToggle: Bool
    public private(set) var showsChapterButtons: Bool

    public static func storageKey(for kind: SpokenWordPlayerKind) -> String {
        "primuse.player.controls.\(kind.rawValue).v1"
    }

    /// 和这个功能出现之前一样:书是语速、定时、书签、目录;播客把书签让给「接下来」
    /// (书签仍能从节目说明面板里加)。
    public static func defaultOrder(for kind: SpokenWordPlayerKind) -> [SpokenWordControlTile] {
        SpokenWordControlTile.allCases.filter { $0.isAvailable(for: kind) }
    }

    public static func defaultHidden(for kind: SpokenWordPlayerKind) -> Set<SpokenWordControlTile> {
        kind == .podcast ? [.bookmark] : []
    }

    public static func `default`(for kind: SpokenWordPlayerKind) -> SpokenWordControlLayout {
        SpokenWordControlLayout(
            kind: kind,
            order: defaultOrder(for: kind),
            hidden: defaultHidden(for: kind),
            showsLike: true,
            showsTranscriptToggle: true,
            showsChapterButtons: true
        )
    }

    private init(
        kind: SpokenWordPlayerKind,
        order: [SpokenWordControlTile],
        hidden: Set<SpokenWordControlTile>,
        showsLike: Bool,
        showsTranscriptToggle: Bool,
        showsChapterButtons: Bool
    ) {
        self.kind = kind
        self.order = Self.completedOrder(order, kind: kind)
        self.hidden = hidden.filter { $0.isAvailable(for: kind) }
        self.showsLike = showsLike
        self.showsTranscriptToggle = showsTranscriptToggle
        self.showsChapterButtons = showsChapterButtons
    }

    // MARK: 存取

    private struct Stored: Codable {
        var order: [String]?
        var hidden: [String]?
        var showsLike: Bool?
        var showsTranscriptToggle: Bool?
        var showsChapterButtons: Bool?
    }

    public static func decode(_ rawValue: String, kind: SpokenWordPlayerKind) -> SpokenWordControlLayout {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default(for: kind)
        }
        let order = (stored.order ?? []).compactMap(SpokenWordControlTile.init(rawValue:))
        var hidden = Set((stored.hidden ?? []).compactMap(SpokenWordControlTile.init(rawValue:)))
        // 存盘时还没有的块(新版本才加的)照默认显隐,别凭空多出或少掉一块。
        let storedNames = Set(stored.order ?? [])
        hidden.formUnion(defaultHidden(for: kind).filter { !storedNames.contains($0.rawValue) })
        return SpokenWordControlLayout(
            kind: kind,
            order: order,
            hidden: hidden,
            showsLike: stored.showsLike ?? true,
            showsTranscriptToggle: stored.showsTranscriptToggle ?? true,
            showsChapterButtons: stored.showsChapterButtons ?? true
        )
    }

    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: order.filter { hidden.contains($0) }.map(\.rawValue),
            showsLike: showsLike ? nil : false,
            showsTranscriptToggle: showsTranscriptToggle ? nil : false,
            showsChapterButtons: showsChapterButtons ? nil : false
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var isDefault: Bool { self == .default(for: kind) }

    public var tilesAreDefault: Bool {
        order == Self.defaultOrder(for: kind) && hidden == Self.defaultHidden(for: kind)
    }

    // MARK: 读

    public func isShown(_ tile: SpokenWordControlTile) -> Bool {
        tile.isAvailable(for: kind) && !hidden.contains(tile)
    }

    /// 页面上那一排按顺序摆哪几块。目录常驻在旁边一栏时(iPad 横屏)不摆目录块;没动过配置时
    /// 那一格照旧让给书签(书签本来就摆着就直接去掉)。
    public func visibleTiles(contentsResident: Bool = false) -> [SpokenWordControlTile] {
        var tiles = order.filter { isShown($0) }
        guard contentsResident, let index = tiles.firstIndex(of: .contents) else { return tiles }
        if tilesAreDefault, !tiles.contains(.bookmark) {
            tiles[index] = .bookmark
        } else {
            tiles.remove(at: index)
        }
        return tiles
    }

    /// 被藏起来、「更多」里原本又没有的入口,要在「更多」里补上:喜欢、书签、播客的「接下来」、文字稿。
    /// 只补用户自己藏的:默认就不出现的(播客的书签)照旧不补。
    public func menuFallback(contentsResident: Bool = false) -> [SpokenWordMenuFallback] {
        var result: [SpokenWordMenuFallback] = []
        if !showsLike { result.append(.like) }
        if !showsTranscriptToggle { result.append(.transcript) }
        let shown = Set(visibleTiles(contentsResident: contentsResident))
        let defaults = SpokenWordControlLayout.default(for: kind)
        let defaultShown = Set(defaults.visibleTiles(contentsResident: contentsResident))
        if defaultShown.contains(.bookmark), !shown.contains(.bookmark) { result.append(.bookmark) }
        if defaultShown.contains(.upNext), !shown.contains(.upNext) { result.append(.upNext) }
        return result
    }

    // MARK: 改

    public func settingTile(_ tile: SpokenWordControlTile, shown: Bool) -> SpokenWordControlLayout {
        guard tile.isAvailable(for: kind) else { return self }
        var copy = self
        if shown { copy.hidden.remove(tile) } else { copy.hidden.insert(tile) }
        return copy
    }

    /// 按编辑页列表里的位置挪动(与 `onMove` 的参数一致)。
    public func movingTiles(fromOffsets source: IndexSet, toOffset destination: Int) -> SpokenWordControlLayout {
        var copy = self
        let moving = source.sorted().map { order[$0] }
        var remaining = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        copy.order = remaining
        return copy
    }

    public func settingShowsLike(_ shows: Bool) -> SpokenWordControlLayout {
        var copy = self
        copy.showsLike = shows
        return copy
    }

    public func settingShowsTranscriptToggle(_ shows: Bool) -> SpokenWordControlLayout {
        var copy = self
        copy.showsTranscriptToggle = shows
        return copy
    }

    public func settingShowsChapterButtons(_ shows: Bool) -> SpokenWordControlLayout {
        var copy = self
        copy.showsChapterButtons = shows
        return copy
    }

    /// 去掉重复与这一种播放页没有的块,缺的按默认顺序插回它在默认里的前一块后面。
    private static func completedOrder(
        _ order: [SpokenWordControlTile],
        kind: SpokenWordPlayerKind
    ) -> [SpokenWordControlTile] {
        var result: [SpokenWordControlTile] = []
        for tile in order where tile.isAvailable(for: kind) && !result.contains(tile) {
            result.append(tile)
        }
        let defaults = defaultOrder(for: kind)
        for (index, tile) in defaults.enumerated() where !result.contains(tile) {
            let previous = defaults[..<index].last { result.contains($0) }
            let position = previous.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(tile, at: position)
        }
        return result
    }
}

/// 有声内容藏起来的入口在「更多」里补的那几项。
public enum SpokenWordMenuFallback: String, CaseIterable, Hashable, Sendable {
    case like
    case transcript
    case bookmark
    case upNext
}
