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
    /// 隔空播放。默认不在这一排(在右上角);打开后右上角那颗不再出现。
    case airPlay

    public var id: String { rawValue }

    public func isAvailable(for kind: SpokenWordPlayerKind) -> Bool {
        self != .upNext || kind == .podcast
    }
}

/// 有声书、播客播放页上能换按钮的格子。rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum SpokenWordControlSlot: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// 播放键那一行的最左、最右两格(通用版面里在上一章 / 下一章外面,关掉上一章 / 下一章时紧挨快退快进)。
    case leadingSide
    case trailingSide
    /// 有声书竖版(iPhone、iPad 竖屏)正在听的那一章右边,默认是上一章 / 下一章。播客没有这一行。
    case partRow

    public var id: String { rawValue }

    public func isAvailable(for kind: SpokenWordPlayerKind) -> Bool {
        self != .partRow || kind == .audiobook
    }
}

/// 格子里能放的按钮。rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum SpokenWordSlotAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case transcript
    /// 书是目录,播客是节目说明。
    case contents
    /// 上一章 / 下一章:左边那格是上一章、右边是下一章,章节那一行放一对。
    case chapters
    case bookmark
    case speed
    case sleepTimer
    /// 播客的「接下来」。
    case upNext
    case like
    /// 「更多」菜单。放进格子后右上角(或标题旁)不再有这一颗。
    case more

    public var id: String { rawValue }

    public func isAvailable(for kind: SpokenWordPlayerKind) -> Bool {
        self != .upNext || kind == .podcast
    }

    /// 功能块那一排里也有的几样。摆在格子里、此刻看得见时,那一排不再重复。
    public var tile: SpokenWordControlTile? {
        switch self {
        case .contents: .contents
        case .bookmark: .bookmark
        case .speed: .speed
        case .sleepTimer: .sleepTimer
        case .upNext: .upNext
        case .transcript, .chapters, .like, .more: nil
        }
    }
}

/// 一格放什么:自动(按这一条有没有文字稿和几个开关,和这个功能出现之前一样)、空着,或者一颗按钮。
public enum SpokenWordSlotChoice: Hashable, Sendable {
    case automatic
    case empty
    case action(SpokenWordSlotAction)

    public var action: SpokenWordSlotAction? {
        if case .action(let action) = self { return action }
        return nil
    }
}

/// 把配置铺到某一种版面上时要知道的事。
public struct SpokenWordControlContext: Equatable, Sendable {
    /// 这一条有带时间的文字稿(字幕、转写稿)。
    public var hasTranscript: Bool
    /// 有章节那一行(有声书竖版)。
    public var hasPartRow: Bool
    /// 播放键两侧那两格摆得出来(手机横屏右栏太窄时让出来)。
    public var showsSides: Bool
    /// 快退、快进紧挨着还有一对上一章 / 下一章的位置(通用竖版、桌面半折、iPad 横屏)。
    /// 两侧那两格在这对外面。
    public var hasInnerChapterPair: Bool
    /// 功能块那一排在这个版面上(手机横屏、iPhone Duo 竖栏没有)。
    public var hasTiles: Bool
    /// 目录常驻在旁边一栏(iPad 横屏):功能块不摆目录。
    public var contentsResident: Bool
    /// 看文字稿时上滑收起了下面的控件:格子与功能块都看不见,右上角那一组照常全在。
    public var controlsCollapsed: Bool

    public init(
        hasTranscript: Bool,
        hasPartRow: Bool = false,
        showsSides: Bool = true,
        hasInnerChapterPair: Bool = false,
        hasTiles: Bool = true,
        contentsResident: Bool = false,
        controlsCollapsed: Bool = false
    ) {
        self.hasTranscript = hasTranscript
        self.hasPartRow = hasPartRow
        self.showsSides = showsSides
        self.hasInnerChapterPair = hasInnerChapterPair
        self.hasTiles = hasTiles
        self.contentsResident = contentsResident
        self.controlsCollapsed = controlsCollapsed
    }
}

/// 一份配置在某种版面上实际怎么摆。
public struct SpokenWordResolvedControls: Equatable, Sendable {
    public var leadingSide: SpokenWordSlotAction?
    public var trailingSide: SpokenWordSlotAction?
    /// 章节那一行右边(只有有声书竖版有)。
    public var partRow: SpokenWordSlotAction?
    /// 快退、快进紧挨着的那一对上一章 / 下一章。
    public var showsInnerChapters: Bool
    /// 功能块那一排按顺序摆哪几块(格子里摆着的不再重复)。
    public var tiles: [SpokenWordControlTile]
    /// 右上角(或标题旁)那一组里各要不要出现。喜欢还要看这一条能不能喜欢。
    public var headerShowsAirPlay: Bool
    public var headerShowsLike: Bool
    public var headerShowsMore: Bool

    /// 两侧有一边有按钮时,另一边留同样大的空位,播放键不偏;两边都空就都不占位。
    public var sidesNeedPlaceholders: Bool {
        leadingSide != nil || trailingSide != nil
    }

    /// 格子里此刻摆出来的按钮。
    public var placedActions: Set<SpokenWordSlotAction> {
        Set([leadingSide, trailingSide, partRow].compactMap { $0 })
    }

    public func action(in slot: SpokenWordControlSlot) -> SpokenWordSlotAction? {
        switch slot {
        case .leadingSide: leadingSide
        case .trailingSide: trailingSide
        case .partRow: partRow
        }
    }
}

/// 有声书、播客播放页那排功能块怎么写字:图标下面(或旁边)带一行说明,还是只放图标。
/// rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum SpokenWordTileLabelStyle: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case iconAndText
    case iconOnly

    public var id: String { rawValue }
}

/// 有声书或播客播放页的按钮:功能块的顺序与显隐,播放键两侧与章节那一行的格子,
/// 喜欢、文字稿键和上一章 / 下一章(格子选「自动」时)的开关,最底下那行显不显示音乐源;
/// 「更多」菜单里关掉的项也记在这里。整份存成一个 JSON 字符串,没改过(或恢复默认)时存空串。
public struct SpokenWordControlLayout: Equatable, Sendable {
    public let kind: SpokenWordPlayerKind
    /// 这一种播放页能出现的全部功能块,按用户排的顺序(含隐藏的)。
    public private(set) var order: [SpokenWordControlTile]
    public private(set) var hidden: Set<SpokenWordControlTile>
    public private(set) var showsLike: Bool
    public private(set) var showsTranscriptToggle: Bool
    public private(set) var showsChapterButtons: Bool
    /// 功能块只放图标还是带说明文字。
    public private(set) var tileLabelStyle: SpokenWordTileLabelStyle
    /// 有声书最底下那行写不写音乐源(不止一个源时才有)。
    public private(set) var showsSource: Bool
    /// 格子 → 存下来的值:按钮名,或空串表示故意空着;没存的格是「自动」。
    /// 认不出的名字原样保留,那一格在这台设备上空着。
    private var slots: [String: String]
    /// 「更多」里关掉的项(`NowPlayingMenuItem.rawValue`),排好序去重;认不出的名字原样保留,
    /// 别的版本关掉的项在这台设备上改别的开关时不会被抹掉。
    private var hiddenMenu: [String]

    public static func storageKey(for kind: SpokenWordPlayerKind) -> String {
        "primuse.player.controls.\(kind.rawValue).v1"
    }

    /// 和这个功能出现之前一样:书是语速、定时、书签、目录;播客把书签让给「接下来」
    /// (书签仍能从节目说明面板里加)。
    public static func defaultOrder(for kind: SpokenWordPlayerKind) -> [SpokenWordControlTile] {
        SpokenWordControlTile.allCases.filter { $0.isAvailable(for: kind) }
    }

    /// 隔空播放默认在右上角,不在这一排。
    public static func defaultHidden(for kind: SpokenWordPlayerKind) -> Set<SpokenWordControlTile> {
        kind == .podcast ? [.bookmark, .airPlay] : [.airPlay]
    }

    public static func `default`(for kind: SpokenWordPlayerKind) -> SpokenWordControlLayout {
        SpokenWordControlLayout(
            kind: kind,
            order: defaultOrder(for: kind),
            hidden: defaultHidden(for: kind),
            showsLike: true,
            showsTranscriptToggle: true,
            showsChapterButtons: true,
            tileLabelStyle: .iconAndText,
            showsSource: true,
            slots: [:],
            hiddenMenu: []
        )
    }

    private init(
        kind: SpokenWordPlayerKind,
        order: [SpokenWordControlTile],
        hidden: Set<SpokenWordControlTile>,
        showsLike: Bool,
        showsTranscriptToggle: Bool,
        showsChapterButtons: Bool,
        tileLabelStyle: SpokenWordTileLabelStyle,
        showsSource: Bool,
        slots: [String: String],
        hiddenMenu: [String]
    ) {
        self.kind = kind
        self.order = Self.completedOrder(order, kind: kind)
        self.hidden = hidden.filter { $0.isAvailable(for: kind) }
        self.showsLike = showsLike
        self.showsTranscriptToggle = showsTranscriptToggle
        self.showsChapterButtons = showsChapterButtons
        self.tileLabelStyle = tileLabelStyle
        self.showsSource = showsSource
        // 这一种播放页没有的格子(播客的章节那一行)不留。
        self.slots = slots.filter { key, _ in
            SpokenWordControlSlot(rawValue: key).map { $0.isAvailable(for: kind) } ?? true
        }
        // 排好序、去重:同一份配置不管先关哪项,比较和编码出来都一样。
        self.hiddenMenu = Array(Set(hiddenMenu)).sorted()
    }

    // MARK: 存取

    private struct Stored: Codable {
        var order: [String]?
        var hidden: [String]?
        var showsLike: Bool?
        var showsTranscriptToggle: Bool?
        var showsChapterButtons: Bool?
        /// `SpokenWordTileLabelStyle.rawValue`;认不出的(别的版本新加的)按默认。
        var labelStyle: String?
        var showsSource: Bool?
        var slots: [String: String]?
        var hiddenMenu: [String]?
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
            showsChapterButtons: stored.showsChapterButtons ?? true,
            tileLabelStyle: stored.labelStyle.flatMap(SpokenWordTileLabelStyle.init(rawValue:)) ?? .iconAndText,
            showsSource: stored.showsSource ?? true,
            slots: stored.slots ?? [:],
            hiddenMenu: stored.hiddenMenu ?? []
        )
    }

    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            order: order.map(\.rawValue),
            hidden: order.filter { hidden.contains($0) }.map(\.rawValue),
            showsLike: showsLike ? nil : false,
            showsTranscriptToggle: showsTranscriptToggle ? nil : false,
            showsChapterButtons: showsChapterButtons ? nil : false,
            labelStyle: tileLabelStyle == .iconAndText ? nil : tileLabelStyle.rawValue,
            showsSource: showsSource ? nil : false,
            slots: slots.isEmpty ? nil : slots,
            hiddenMenu: hiddenMenu.isEmpty ? nil : hiddenMenu
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

    /// 「更多」里这一项要不要出现。页面上藏起来后补进菜单的喜欢、文字稿、书签、「接下来」
    /// 不在这里管,那是兜底入口,关不掉。
    public func showsMenuItem(_ item: NowPlayingMenuItem) -> Bool {
        !hiddenMenu.contains(item.rawValue)
    }

    /// 「更多」里关掉的项。
    public var hiddenMenuItems: Set<NowPlayingMenuItem> {
        Set(NowPlayingMenuItem.allCases.filter { !showsMenuItem($0) })
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

    /// 这一格选的是什么。没存过是「自动」;存的按钮这一种播放页没有(或认不出)时当作空着。
    public func choice(in slot: SpokenWordControlSlot) -> SpokenWordSlotChoice {
        guard slot.isAvailable(for: kind), let raw = slots[slot.rawValue] else { return .automatic }
        guard let action = SpokenWordSlotAction(rawValue: raw), action.isAvailable(for: kind) else {
            return .empty
        }
        return .action(action)
    }

    /// 「自动」此刻放什么,和这个功能出现之前一样:有文字稿(且没关文字稿键)时左边文字稿、右边目录
    /// (目录块关了就空着);没有时是上一章 / 下一章,版面另有放章节的地方(章节那一行、紧挨快退快进
    /// 的那一对)就空着。章节那一行自动是上一章 / 下一章。
    public func automaticAction(
        in slot: SpokenWordControlSlot,
        context: SpokenWordControlContext
    ) -> SpokenWordSlotAction? {
        let transcriptOnPage = context.hasTranscript && showsTranscriptToggle
        switch slot {
        case .partRow:
            return showsChapterButtons ? .chapters : nil
        case .leadingSide where transcriptOnPage:
            return .transcript
        case .trailingSide where transcriptOnPage:
            return isShown(.contents) ? .contents : nil
        case .leadingSide, .trailingSide:
            let chaptersElsewhere = context.hasPartRow || context.hasInnerChapterPair
            return !chaptersElsewhere && showsChapterButtons ? .chapters : nil
        }
    }

    /// 铺到某一种版面上:每一格放什么、功能块摆哪几块、右上角那一组里还剩哪几颗。
    /// 同一颗键只出现一次(两侧的上一章与下一章是两颗):两侧先摆,章节那一行再摆,
    /// 功能块里去掉格子里已经有的;隔空播放进了功能块,右上角就不再放。
    public func resolved(in context: SpokenWordControlContext) -> SpokenWordResolvedControls {
        var placed = Set<SpokenWordSlotAction>()
        func place(_ slot: SpokenWordControlSlot, visible: Bool) -> SpokenWordSlotAction? {
            guard visible, slot.isAvailable(for: kind) else { return nil }
            let action: SpokenWordSlotAction?
            switch choice(in: slot) {
            case .automatic: action = automaticAction(in: slot, context: context)
            case .empty: action = nil
            case .action(let picked):
                // 没有文字稿的那一条,文字稿那一格空着。
                action = picked == .transcript && !context.hasTranscript ? nil : picked
            }
            guard let action else { return nil }
            let pairsWithOtherSide = action == .chapters && slot != .partRow
            if placed.contains(action), !pairsWithOtherSide { return nil }
            placed.insert(action)
            return action
        }

        let sidesVisible = context.showsSides && !context.controlsCollapsed
        let leading = place(.leadingSide, visible: sidesVisible)
        let trailing = place(.trailingSide, visible: sidesVisible)
        let partRow = place(.partRow, visible: context.hasPartRow && !context.controlsCollapsed)
        let showsInnerChapters = context.hasInnerChapterPair && !context.controlsCollapsed
            && showsChapterButtons && !placed.contains(.chapters)

        var tiles: [SpokenWordControlTile] = []
        if context.hasTiles, !context.controlsCollapsed {
            // 目录在旁边一栏常驻,或者摆进了格子:和原来一样,没动过功能块时那一格让给书签。
            let contentsElsewhere = context.contentsResident || placed.contains(.contents)
            let inSlots = Set(placed.compactMap(\.tile))
            tiles = visibleTiles(contentsResident: contentsElsewhere).filter { !inSlots.contains($0) }
        }

        return SpokenWordResolvedControls(
            leadingSide: leading,
            trailingSide: trailing,
            partRow: partRow,
            showsInnerChapters: showsInnerChapters,
            tiles: tiles,
            headerShowsAirPlay: !tiles.contains(.airPlay),
            headerShowsLike: showsLike && !placed.contains(.like),
            headerShowsMore: !placed.contains(.more)
        )
    }

    /// 页面上点不到、「更多」里原本又没有的入口,在「更多」里补上:喜欢、文字稿、书签、播客的「接下来」。
    /// 只补用户自己挪走或藏起来的:默认在这个版面上也不出现的(播客的书签)照旧不补。没有功能块的版面
    /// (手机横屏、iPhone Duo 竖栏)只看喜欢。
    public func menuFallback(
        for resolved: SpokenWordResolvedControls,
        context: SpokenWordControlContext
    ) -> [SpokenWordMenuFallback] {
        var result: [SpokenWordMenuFallback] = []
        if !resolved.headerShowsLike, !resolved.placedActions.contains(.like) { result.append(.like) }
        guard context.hasTiles else { return result }
        if context.hasTranscript, !resolved.placedActions.contains(.transcript) { result.append(.transcript) }
        let defaults = SpokenWordControlLayout.default(for: kind).resolved(in: context)
        func reachable(_ controls: SpokenWordResolvedControls) -> Set<SpokenWordControlTile> {
            Set(controls.tiles).union(controls.placedActions.compactMap(\.tile))
        }
        let shown = reachable(resolved)
        let defaultShown = reachable(defaults)
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

    public func settingTileLabelStyle(_ style: SpokenWordTileLabelStyle) -> SpokenWordControlLayout {
        var copy = self
        copy.tileLabelStyle = style
        return copy
    }

    public func settingShowsSource(_ shows: Bool) -> SpokenWordControlLayout {
        var copy = self
        copy.showsSource = shows
        return copy
    }

    /// 给一格换按钮。这颗按钮原来明确放在另一格时两格对调(上一章 / 下一章在两侧各放一颗不算重复)。
    public func placing(_ choice: SpokenWordSlotChoice, in slot: SpokenWordControlSlot) -> SpokenWordControlLayout {
        guard slot.isAvailable(for: kind) else { return self }
        if let action = choice.action, !action.isAvailable(for: kind) { return self }
        var copy = self
        let previous = slots[slot.rawValue]
        if let action = choice.action {
            let pairsAcrossSides = action == .chapters && slot != .partRow
            for other in SpokenWordControlSlot.allCases where other != slot && self.choice(in: other) == choice {
                if pairsAcrossSides, other != .partRow { continue }
                copy.slots[other.rawValue] = previous
            }
        }
        switch choice {
        case .automatic: copy.slots.removeValue(forKey: slot.rawValue)
        case .empty: copy.slots[slot.rawValue] = ""
        case .action(let action): copy.slots[slot.rawValue] = action.rawValue
        }
        return copy
    }

    /// 几个格子全部回到「自动」,别的不动。
    public func resettingSlots() -> SpokenWordControlLayout {
        var copy = self
        copy.slots = [:]
        return copy
    }

    public var slotsAreAutomatic: Bool {
        SpokenWordControlSlot.allCases.allSatisfy { choice(in: $0) == .automatic }
    }

    public func settingMenuItem(_ item: NowPlayingMenuItem, visible: Bool) -> SpokenWordControlLayout {
        var copy = self
        var names = hiddenMenu.filter { $0 != item.rawValue }
        if !visible { names.append(item.rawValue) }
        copy.hiddenMenu = names.sorted()
        return copy
    }

    /// 「更多」里的项全部显示回来。
    public func showingAllMenuItems() -> SpokenWordControlLayout {
        var copy = self
        copy.hiddenMenu = []
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
