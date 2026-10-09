import Foundation

/// 播放页上能摆出来的按钮。
///
/// rawValue 会写进配置并经 iCloud 同步,case 名一旦发布就不能改:读回来认不出的名字
/// 只让那一个位置空着,不让整份配置退回默认。
public enum NowPlayingControlAction: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case like
    case dislike
    case lyrics
    case airPlay
    case queue
    case shuffle
    case repeatMode = "repeat"
    case sleepTimer
    case equalizer
    case playbackSpeed
    case karaoke
    case fullScreen
    case addToPlaylist
    case share
    case cast

    public var id: String { rawValue }

    /// 隔空播放用的是系统那颗必须直接点的按钮,收不进「更多」菜单,所以只能挪位置、不能拿掉。
    public var isRequiredOnPage: Bool { self == .airPlay }

    /// 能不能放在播放键那一行的两端。隔空播放不放那里:手机横屏窄的时候两端会让出来,
    /// 它一让就找不到了。
    public var fitsTransportEdge: Bool { self != .airPlay }

    /// 「更多」里本来没有、只能靠页面上那颗键点到的几样。没摆在页面上时补进「更多」。
    public var needsMenuFallback: Bool {
        switch self {
        case .like, .lyrics, .queue, .shuffle, .repeatMode: true
        default: false
        }
    }

    /// 「更多」里本来就有的几样。摆在页面上、此刻也看得见时,菜单里就不再重复。
    public var duplicatesMenuItem: Bool {
        switch self {
        case .dislike, .sleepTimer, .equalizer, .playbackSpeed, .karaoke,
             .fullScreen, .addToPlaylist, .share, .cast:
            true
        case .like, .lyrics, .airPlay, .queue, .shuffle, .repeatMode:
            false
        }
    }
}

/// 音乐播放页上可以换按钮的六个位置。版面里的位置数和尺寸不变,只换放什么。
public enum NowPlayingControlSlot: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// 歌名右侧、「更多」左边。
    case header
    /// 播放键那一行的最左、最右。
    case leadingEdge
    case trailingEdge
    /// 最下面那一排的左、中、右。
    case barLeading
    case barCenter
    case barTrailing

    public var id: String { rawValue }

    public static let transportEdges: [Self] = [.leadingEdge, .trailingEdge]
    public static let bar: [Self] = [.barLeading, .barCenter, .barTrailing]

    public var isTransportEdge: Bool { Self.transportEdges.contains(self) }
}

/// 音乐播放页「更多」菜单里能关掉的项(#198:串烧、卡拉OK 这类用得少的可以不出现)。
/// rawValue 会写进配置并经 iCloud 同步,发布后不能改名。页面按钮缺了时补进菜单的那几项(喜欢、歌词、队列、
/// 随机、循环)不在这里——那是兜底入口,不能关。
public enum NowPlayingMenuItem: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case fullScreen
    case share
    case addToPlaylist
    case delete
    case karaoke
    case medley
    case scrape
    case reloadLyrics
    case similarSongs
    case dislike
    case playbackRange
    case editTags
    case editLyrics
    case songInfo
    case goToAlbum
    case goToArtist
    case openInAppleMusic
    case cast
    case lyricsDisplay
    case lyricsMotion
    case sleepTimer
    case equalizer
    case playbackSpeed

    public var id: String { rawValue }
}

/// 播放页最底下那行状态里的三项。
public enum NowPlayingStatusItem: String, CaseIterable, Codable, Hashable, Sendable {
    case source
    case output
    case sleepTimer
}

/// 一份配置要铺到哪种版面上。各版面位置不一样多,按这里的规则取用同一份配置。
public enum NowPlayingControlSurface: Equatable, Sendable {
    /// 竖屏(含桌面半折的下半屏):六个位置都在。
    case portrait
    /// 手机横屏:顶上那排圆钮放底栏和歌名旁的按钮;歌词在右栏,全屏有自己那颗键。
    case compactLandscape(showsTransportEdges: Bool)
    /// iPad 横屏左栏:歌词常驻右栏,底栏不放歌词键。
    case wideLandscape
    /// iPhone Duo 竖栏那一列:中间一组放底栏除 AirPlay 外的按钮,下面一组是歌名旁那一格、
    /// AirPlay、全屏效果、锁和更多。高度不够时歌名旁那一格会收进「更多」。
    case toolColumn(showsTransportEdges: Bool, headerOverflows: Bool)
    /// 全屏歌词:顶上那排只有歌名旁那一格跟配置走(原来的心形位置),底座只有播放键。
    /// 别的按钮这里本来就不出现,不往「更多」里补。
    case immersiveLyrics

    var showsTransportEdges: Bool {
        switch self {
        case .portrait, .wideLandscape: true
        case .compactLandscape(let shows): shows
        case .toolColumn(let shows, _): shows
        case .immersiveLyrics: false
        }
    }

    /// 这种版面上不靠配置也一直点得到的(或者这里本来就不提供、不用补的)。
    var alwaysReachable: Set<NowPlayingControlAction> {
        switch self {
        case .portrait: []
        case .compactLandscape: [.lyrics, .fullScreen]
        case .wideLandscape: [.lyrics]
        case .toolColumn: [.airPlay, .fullScreen]
        case .immersiveLyrics: [.lyrics, .queue, .shuffle, .repeatMode, .airPlay, .fullScreen]
        }
    }
}

/// 音乐播放页的按钮摆法与底部状态行显示哪几项。整份存成一个 JSON 字符串,没改过(或恢复默认)
/// 时存空串;只记和默认不同的位置,所以以后改默认也能跟上没动过的那几格。
public struct NowPlayingControlLayout: Equatable, Sendable {
    public static let musicStorageKey = "primuse.player.controls.music.v1"

    /// 和这个功能出现之前的播放页一模一样。
    public static let defaultActions: [NowPlayingControlSlot: NowPlayingControlAction] = [
        .header: .like,
        .leadingEdge: .shuffle,
        .trailingEdge: .repeatMode,
        .barLeading: .lyrics,
        .barCenter: .airPlay,
        .barTrailing: .queue,
    ]

    public static let `default` = NowPlayingControlLayout(stored: [:], hiddenStatus: [], hiddenMenu: [])

    /// 位置 → 存下来的值:动作名,或空串表示这一格故意空着。认不出的名字原样保留,
    /// 别的版本写进来的新按钮在这台设备上空着,但改别的格时不会被抹掉。
    private var stored: [String: String]
    private var hiddenStatus: [String]
    /// 「更多」里关掉的项,认不出的名字原样保留。
    private var hiddenMenu: [String]
    /// 归一之后每一格实际放的按钮。
    public private(set) var actions: [NowPlayingControlSlot: NowPlayingControlAction]

    private init(stored: [String: String], hiddenStatus: [String], hiddenMenu: [String]) {
        self.stored = stored
        // 排好序、去重:同一份配置不管先关哪项,比较和编码出来都一样。
        self.hiddenStatus = Array(Set(hiddenStatus)).sorted()
        self.hiddenMenu = Array(Set(hiddenMenu)).sorted()
        self.actions = Self.resolve(stored)
    }

    // MARK: 存取

    private struct Stored: Codable {
        var slots: [String: String]?
        var hiddenStatus: [String]?
        var hiddenMenu: [String]?
    }

    public static func decode(_ rawValue: String) -> NowPlayingControlLayout {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        return NowPlayingControlLayout(
            stored: decoded.slots ?? [:],
            hiddenStatus: decoded.hiddenStatus ?? [],
            hiddenMenu: decoded.hiddenMenu ?? []
        )
    }

    /// 默认配置编成空串。键按字母排,同样的配置每次编出同一个字符串,同步那边不会误以为变了。
    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            slots: stored.isEmpty ? nil : stored,
            hiddenStatus: hiddenStatus.isEmpty ? nil : hiddenStatus,
            hiddenMenu: hiddenMenu.isEmpty ? nil : hiddenMenu
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var isDefault: Bool {
        actions == Self.defaultActions && hiddenStatus.isEmpty && hiddenMenu.isEmpty
    }

    // MARK: 读

    public func action(in slot: NowPlayingControlSlot) -> NowPlayingControlAction? {
        actions[slot]
    }

    public func slot(of action: NowPlayingControlAction) -> NowPlayingControlSlot? {
        NowPlayingControlSlot.allCases.first { actions[$0] == action }
    }

    public var placedActions: Set<NowPlayingControlAction> {
        Set(actions.values)
    }

    public func showsStatusItem(_ item: NowPlayingStatusItem) -> Bool {
        !hiddenStatus.contains(item.rawValue)
    }

    public func showsMenuItem(_ item: NowPlayingMenuItem) -> Bool {
        !hiddenMenu.contains(item.rawValue)
    }

    /// 「更多」里关掉的项,按目录顺序。
    public var hiddenMenuItems: Set<NowPlayingMenuItem> {
        Set(NowPlayingMenuItem.allCases.filter { !showsMenuItem($0) })
    }

    // MARK: 改

    /// 能不能把 `action` 放进 `slot`(`nil` 是把这一格空出来)。放进去的按钮原来在别的格时
    /// 两格对调;隔空播放不能因此被挤掉,也不能被换到两端。
    public func canPlace(_ action: NowPlayingControlAction?, in slot: NowPlayingControlSlot) -> Bool {
        let current = actions[slot]
        guard action != current else { return true }
        if let action, slot.isTransportEdge, !action.fitsTransportEdge { return false }
        guard current?.isRequiredOnPage == true else { return true }
        // 这一格现在是隔空播放:只有新按钮原来也在页面上(而且不在两端)时,两格对调才留得住它。
        guard let action, let from = self.slot(of: action) else { return false }
        return !from.isTransportEdge
    }

    /// 放不进去时原样返回。
    public func placing(_ action: NowPlayingControlAction?, in slot: NowPlayingControlSlot) -> NowPlayingControlLayout {
        guard canPlace(action, in: slot), action != actions[slot] else { return self }
        var next = actions
        let displaced = next[slot]
        if let action, let from = self.slot(of: action) {
            next[from] = displaced
        }
        next[slot] = action
        return with(actions: next)
    }

    public func settingStatusItem(_ item: NowPlayingStatusItem, visible: Bool) -> NowPlayingControlLayout {
        var hidden = hiddenStatus.filter { $0 != item.rawValue }
        if !visible { hidden.append(item.rawValue) }
        return NowPlayingControlLayout(stored: stored, hiddenStatus: hidden, hiddenMenu: hiddenMenu)
    }

    public func settingMenuItem(_ item: NowPlayingMenuItem, visible: Bool) -> NowPlayingControlLayout {
        var hidden = hiddenMenu.filter { $0 != item.rawValue }
        if !visible { hidden.append(item.rawValue) }
        return NowPlayingControlLayout(stored: stored, hiddenStatus: hiddenStatus, hiddenMenu: hidden)
    }

    /// 「更多」里的项全部显示回来。
    public func showingAllMenuItems() -> NowPlayingControlLayout {
        var copy = self
        copy.hiddenMenu = []
        return copy
    }

    /// 只恢复按钮,状态行的显隐不动。
    public func resettingActions() -> NowPlayingControlLayout {
        var copy = self
        copy.stored = [:]
        copy.actions = Self.defaultActions
        return copy
    }

    private func with(actions next: [NowPlayingControlSlot: NowPlayingControlAction]) -> NowPlayingControlLayout {
        var stored = self.stored
        for slot in NowPlayingControlSlot.allCases {
            let value = next[slot]
            if value == Self.defaultActions[slot] {
                stored.removeValue(forKey: slot.rawValue)
            } else if value != actions[slot] || stored[slot.rawValue] == nil {
                stored[slot.rawValue] = value?.rawValue ?? ""
            }
        }
        return NowPlayingControlLayout(stored: stored, hiddenStatus: hiddenStatus, hiddenMenu: hiddenMenu)
    }

    /// 没存的格取默认;同一个按钮出现两次只留前面那格;隔空播放不在页面上(别处改坏、
    /// 或别的版本允许拿掉)时补回一格,先找空着的,没有就占回默认的正中。
    private static func resolve(_ stored: [String: String]) -> [NowPlayingControlSlot: NowPlayingControlAction] {
        var result: [NowPlayingControlSlot: NowPlayingControlAction] = [:]
        var seen = Set<NowPlayingControlAction>()
        for slot in NowPlayingControlSlot.allCases {
            let action: NowPlayingControlAction?
            if let raw = stored[slot.rawValue] {
                action = NowPlayingControlAction(rawValue: raw)
            } else {
                action = defaultActions[slot]
            }
            guard let action, !seen.contains(action) else { continue }
            if slot.isTransportEdge, !action.fitsTransportEdge { continue }
            seen.insert(action)
            result[slot] = action
        }
        if !seen.contains(.airPlay) {
            let candidates: [NowPlayingControlSlot] = [.barCenter, .barLeading, .barTrailing, .header]
            let target = candidates.first { result[$0] == nil } ?? .barCenter
            result[target] = .airPlay
        }
        return result
    }

    // MARK: 铺到各版面

    /// 手机横屏顶上那排圆钮:左边一组放底栏的按钮(歌词在右栏、全屏有自己那颗键,不放),
    /// 隔空播放排在这一组最后,和原来的样子一致;右边歌名旁那一格。
    public func compactLandscapeChrome() -> (leading: [NowPlayingControlAction], trailing: NowPlayingControlAction?) {
        let skipped: Set<NowPlayingControlAction> = [.lyrics, .fullScreen]
        let bar = NowPlayingControlSlot.bar.compactMap { actions[$0] }.filter { !skipped.contains($0) }
        let leading = bar.filter { $0 != .airPlay } + bar.filter { $0 == .airPlay }
        let header = actions[.header].flatMap { skipped.contains($0) ? nil : $0 }
        return (leading, header)
    }

    /// iPad 横屏左栏最下面那排:歌词常驻右栏,不放歌词键。
    public func wideLandscapeBar() -> [NowPlayingControlAction] {
        NowPlayingControlSlot.bar.compactMap { actions[$0] }.filter { $0 != .lyrics }
    }

    /// iPhone Duo 竖栏那一列:中间一组(底栏里除 AirPlay 外的按钮)和下面一组里歌名旁那一格。
    public func toolColumnGroups() -> (middle: [NowPlayingControlAction], header: NowPlayingControlAction?) {
        let middle = NowPlayingControlSlot.bar.compactMap { actions[$0] }.filter { $0 != .airPlay }
        let header = actions[.header].flatMap { $0 == .airPlay || $0 == .fullScreen ? nil : $0 }
        return (middle, header)
    }

    /// 全屏歌词顶上那排原来心形的位置。
    public func immersiveLyricsAction() -> NowPlayingControlAction? {
        actions[.header].flatMap { [.lyrics, .fullScreen, .airPlay].contains($0) ? nil : $0 }
    }

    /// 这种版面上按配置真的摆出来、看得见的按钮。
    public func visibleActions(on surface: NowPlayingControlSurface) -> Set<NowPlayingControlAction> {
        var visible = Set<NowPlayingControlAction>()
        if surface.showsTransportEdges {
            visible.formUnion(NowPlayingControlSlot.transportEdges.compactMap { actions[$0] })
        }
        switch surface {
        case .portrait:
            visible.formUnion(NowPlayingControlSlot.bar.compactMap { actions[$0] })
            if let header = actions[.header] { visible.insert(header) }
        case .compactLandscape:
            let chrome = compactLandscapeChrome()
            visible.formUnion(chrome.leading)
            if let trailing = chrome.trailing { visible.insert(trailing) }
        case .wideLandscape:
            visible.formUnion(wideLandscapeBar())
            if let header = actions[.header] { visible.insert(header) }
        case .toolColumn(_, let headerOverflows):
            let groups = toolColumnGroups()
            visible.formUnion(groups.middle)
            if let header = groups.header, !headerOverflows { visible.insert(header) }
        case .immersiveLyrics:
            if let action = immersiveLyricsAction() { visible.insert(action) }
        }
        return visible
    }

    /// 页面上点不到、要补进「更多」的,按目录顺序。
    public func menuFallback(on surface: NowPlayingControlSurface) -> [NowPlayingControlAction] {
        let reachable = visibleActions(on: surface).union(surface.alwaysReachable)
        return NowPlayingControlAction.allCases.filter { $0.needsMenuFallback && !reachable.contains($0) }
    }

    /// 已经摆在页面上、「更多」里不再重复的。
    public func menuSuppressed(on surface: NowPlayingControlSurface) -> Set<NowPlayingControlAction> {
        visibleActions(on: surface).filter(\.duplicatesMenuItem)
    }
}
