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

/// 音乐播放页上的单格:歌名旁、播放键那一行两端。最下面那一排是一串按钮(`NowPlayingControlLayout.bar`),
/// 不是格子。rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum NowPlayingControlSlot: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// 歌名右侧、「更多」左边。
    case header
    /// 播放键那一行的最左、最右。
    case leadingEdge
    case trailingEdge
    /// 旧版最下面那一排固定的左、中、右三格。现在那一排是一串按钮,这三个名字只用来读写旧配置:
    /// 没升级的设备只认它们,存的时候照这一串的前三颗写一份给它们看。
    case barLeading
    case barCenter
    case barTrailing

    public var id: String { rawValue }

    /// 页面上真正的单格。
    public static let single: [Self] = [.header, .leadingEdge, .trailingEdge]
    public static let transportEdges: [Self] = [.leadingEdge, .trailingEdge]
    static let legacyBar: [Self] = [.barLeading, .barCenter, .barTrailing]

    public var isTransportEdge: Bool { Self.transportEdges.contains(self) }
}

/// 音乐播放页上放按钮的地方:一个单格,或者最下面那一排里的第几颗。
public enum NowPlayingControlPosition: Hashable, Sendable {
    case slot(NowPlayingControlSlot)
    /// 最下面那一排从左数第几颗(从 0 起)。等于这一排现有的颗数时是「添到最后」。
    case bar(Int)
}

/// 最下面那一排一行摆得下几颗、怎么排开。音乐的底栏、有声书与播客那排功能块共用这一个上限:编辑页按这台
/// 设备的宽度限颗数;别的设备同步过来的比这里摆得下的多时照样全摆出来,只是间距收紧,不藏起来。
public enum NowPlayingBarMetrics {
    /// 一颗键的点按范围。
    public static let itemWidth = 44.0
    /// 两颗之间至少空出的距离(按点按范围算)。
    public static let minimumGap = 8.0
    /// 两头收进来的距离:颗数少时和原来三颗一样收 46,颗数多了放不下才往 20 收。
    public static let preferredInset = 46.0
    public static let minimumInset = 20.0
    /// 再宽的屏也只排这么多,一排太多就认不出谁是谁了。
    public static let maximumCount = 8

    /// 宽 `width` 的一排最多放几颗:两头各收 20、每两颗之间至少 8。
    public static func capacity(forWidth width: Double) -> Int {
        guard width.isFinite, width > 0 else { return 1 }
        let fits = ((width - 2 * minimumInset + minimumGap) / (itemWidth + minimumGap)).rounded(.down)
        return min(maximumCount, max(1, Int(fits)))
    }

    /// 两颗时怎么摆:分在两头,或者一颗在正中、一颗靠右(iPad 横屏左栏,默认那里就是投放在中、队列在右)。
    public enum PairArrangement: Sendable {
        case ends
        case centerAndTrailing
    }

    /// 一排 `count` 颗时各颗的中心,从这一排左边量起。一颗在正中;两颗按 `pair` 摆;三颗以上平均排开,
    /// 头尾两颗离边 `preferredInset`(按点按范围的外沿算),挤不下时往 `minimumInset` 收,再挤不下就让间距变小。
    public static func centers(
        count: Int,
        width: Double,
        preferredInset: Double = preferredInset,
        pair: PairArrangement = .ends
    ) -> [Double] {
        guard count > 0 else { return [] }
        let half = itemWidth / 2
        guard count > 1, width > itemWidth else { return Array(repeating: width / 2, count: count) }
        let needed = Double(count) * itemWidth + Double(count - 1) * minimumGap
        let inset = min(preferredInset, max(minimumInset, (width - needed) / 2))
        let first = inset + half
        let last = width - inset - half
        guard last > first else { return Array(repeating: width / 2, count: count) }
        if count == 2, pair == .centerAndTrailing {
            return [width / 2, last]
        }
        let step = (last - first) / Double(count - 1)
        return (0..<count).map { first + Double($0) * step }
    }
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
    // 下面几项只在有声书、播客的菜单里出现(`SpokenWordControlLayout` 管它们的显隐)。
    case goToBook
    case chaptersAndBookmarks
    case podcastEpisodeDetails
    case podcastGoToShow
    case podcastMarkPlayed
    case podcastDownload
    /// 「铃声与导出」,原来跟着播放时间段一起开关。
    case clipExport
    /// 有声书、播客的「生成文字稿」。正在生成时那一行是进度,关掉也照样显示。
    case generateTranscript
    /// 竖屏原生全屏里顶替「全屏」那一格的封面 / 歌词切换。
    case immersiveFaceToggle
    /// 「随机时连播」(#335)。
    case shuffleLink
    /// 把歌词、有声书或播客的文字稿存成 LRC / SRT / 纯文本(#362)。
    case exportText

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
    /// 竖屏(含桌面半折的下半屏):三个单格和最下面那一排都在。
    case portrait
    /// 手机横屏:顶上那排圆钮放底栏和歌名旁的按钮;歌词在右栏,全屏有自己那颗键。那一排窄到放不下底栏
    /// 那一串时左边一组只摆 `leadingLimit` 颗(AirPlay 总在)。
    case compactLandscape(showsTransportEdges: Bool, leadingLimit: Int = .max)
    /// iPad 横屏左栏:歌词常驻右栏,底栏不放歌词键。
    case wideLandscape
    /// iPhone Duo 竖栏那一列:中间一组放底栏除 AirPlay 外的按钮(高度不够时只放前 `middleLimit` 颗),
    /// 下面一组是歌名旁那一格、AirPlay、全屏效果、锁和更多。高度不够时歌名旁那一格会收进「更多」。
    case toolColumn(showsTransportEdges: Bool, headerOverflows: Bool, middleLimit: Int = .max)
    /// 全屏歌词:顶上那排只有歌名旁那一格跟配置走(原来的心形位置),底座只有播放键。
    /// 别的按钮这里本来就不出现,不往「更多」里补。
    case immersiveLyrics
    /// 竖屏看歌词:封面那一面的位置之外,歌词页顶上歌名旁多一格(没有时为 nil)。
    case portraitLyrics(headerExtra: NowPlayingControlAction?)
    /// 按「全屏歌词」那份配置摆出来的全屏歌词,`visible` 是那几格此刻实际摆的按钮。
    case configuredImmersiveLyrics(visible: Set<NowPlayingControlAction>)

    var showsTransportEdges: Bool {
        switch self {
        case .portrait, .wideLandscape, .portraitLyrics: true
        case .compactLandscape(let shows, _): shows
        case .toolColumn(let shows, _, _): shows
        case .immersiveLyrics, .configuredImmersiveLyrics: false
        }
    }

    /// 这种版面上不靠配置也一直点得到的(或者这里本来就不提供、不用补的)。
    var alwaysReachable: Set<NowPlayingControlAction> {
        switch self {
        case .portrait, .portraitLyrics: []
        case .compactLandscape: [.lyrics, .fullScreen]
        case .wideLandscape: [.lyrics]
        case .toolColumn: [.airPlay, .fullScreen]
        case .immersiveLyrics, .configuredImmersiveLyrics:
            [.lyrics, .queue, .shuffle, .repeatMode, .airPlay, .fullScreen]
        }
    }
}

/// 音乐播放页的按钮摆法与底部状态行显示哪几项。整份存成一个 JSON 字符串,没改过(或恢复默认)
/// 时存空串;单格只记和默认不同的,所以以后改默认也能跟上没动过的那几格。最下面那一排是一串按钮,
/// 和默认那一串(歌词 · 投放 · 队列)不一样时整串记下来。
public struct NowPlayingControlLayout: Equatable, Sendable {
    public static let musicStorageKey = "primuse.player.controls.music.v1"

    /// 三个单格的默认,和这个功能出现之前的播放页一模一样。
    public static let defaultActions: [NowPlayingControlSlot: NowPlayingControlAction] = [
        .header: .like,
        .leadingEdge: .shuffle,
        .trailingEdge: .repeatMode,
    ]

    /// 最下面那一排的默认。
    public static let defaultBar: [NowPlayingControlAction] = [.lyrics, .airPlay, .queue]

    /// 旧版底栏三格的默认,读旧配置时没存的格按它补。
    private static let legacyBarDefaults: [NowPlayingControlSlot: NowPlayingControlAction] = [
        .barLeading: .lyrics,
        .barCenter: .airPlay,
        .barTrailing: .queue,
    ]

    public static let `default` = NowPlayingControlLayout(stored: [:], storedBar: nil, hiddenStatus: [], hiddenMenu: [])

    /// 单格 → 存下来的值:动作名,或空串表示这一格故意空着。认不出的名字原样保留,
    /// 别的版本写进来的新按钮在这台设备上空着,但改别的格时不会被抹掉。
    /// 没有 `storedBar` 时(没动过底栏,或者是旧版本写的配置)这里还可能有旧版底栏那三格。
    private var stored: [String: String]
    /// 最下面那一排按顺序存的按钮名,认不出的名字原样保留。nil 是这一排还按旧版三格(`stored`)或默认读。
    private var storedBar: [String]?
    private var hiddenStatus: [String]
    /// 「更多」里关掉的项,认不出的名字原样保留。
    private var hiddenMenu: [String]
    /// 归一之后三个单格实际放的按钮。
    public private(set) var actions: [NowPlayingControlSlot: NowPlayingControlAction]
    /// 归一之后最下面那一排从左到右的按钮。颗数不限,版面按自己摆得下的排开。
    public private(set) var bar: [NowPlayingControlAction]

    private init(stored: [String: String], storedBar: [String]?, hiddenStatus: [String], hiddenMenu: [String]) {
        // 存了整串时旧版三格只是写给旧版本看的副本,读回来不用,存的时候照这一串重新写。
        self.stored = storedBar == nil
            ? stored
            : stored.filter { key, _ in !NowPlayingControlSlot.legacyBar.map(\.rawValue).contains(key) }
        self.storedBar = storedBar
        // 排好序、去重:同一份配置不管先关哪项,比较和编码出来都一样。
        self.hiddenStatus = Array(Set(hiddenStatus)).sorted()
        self.hiddenMenu = Array(Set(hiddenMenu)).sorted()
        let resolved = Self.resolve(stored: self.stored, storedBar: storedBar)
        self.actions = resolved.actions
        self.bar = resolved.bar.compactMap(\.action)
    }

    // MARK: 存取

    private struct Stored: Codable {
        var slots: [String: String]?
        var bar: [String]?
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
            storedBar: decoded.bar,
            hiddenStatus: decoded.hiddenStatus ?? [],
            hiddenMenu: decoded.hiddenMenu ?? []
        )
    }

    /// 默认配置编成空串。键按字母排,同样的配置每次编出同一个字符串,同步那边不会误以为变了。
    /// 存了整串底栏时,旧版三格照这一串的前几颗写一份:没升级的设备至少看得到前三颗。
    public func encoded() -> String {
        guard !isDefault else { return "" }
        var slots = stored
        if storedBar != nil {
            for (slot, action) in Self.legacyProjection(of: bar) {
                slots[slot.rawValue] = action?.rawValue ?? ""
            }
        }
        let payload = Stored(
            slots: slots.isEmpty ? nil : slots,
            bar: storedBar,
            hiddenStatus: hiddenStatus.isEmpty ? nil : hiddenStatus,
            hiddenMenu: hiddenMenu.isEmpty ? nil : hiddenMenu
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    public var isDefault: Bool {
        actions == Self.defaultActions && buttonsAreDefault && hiddenStatus.isEmpty && hiddenMenu.isEmpty
    }

    /// 按钮摆法(单格与最下面那一排)和默认一样,别的版本写进来的认不出的名字也没有。
    public var buttonsAreDefault: Bool {
        actions == Self.defaultActions && bar == Self.defaultBar
            && barEntries.allSatisfy { $0.action != nil }
    }

    // MARK: 读

    /// 单格里放的按钮(旧版底栏那三格一律是 nil,底栏看 `bar`)。
    public func action(in slot: NowPlayingControlSlot) -> NowPlayingControlAction? {
        actions[slot]
    }

    public func position(of action: NowPlayingControlAction) -> NowPlayingControlPosition? {
        if let slot = NowPlayingControlSlot.single.first(where: { actions[$0] == action }) {
            return .slot(slot)
        }
        return bar.firstIndex(of: action).map(NowPlayingControlPosition.bar)
    }

    public func action(at position: NowPlayingControlPosition) -> NowPlayingControlAction? {
        switch position {
        case .slot(let slot): actions[slot]
        case .bar(let index): bar.indices.contains(index) ? bar[index] : nil
        }
    }

    public var placedActions: Set<NowPlayingControlAction> {
        Set(actions.values).union(bar)
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

    /// 能不能把 `action` 放到 `position`(`nil` 是空出这一格、从这一排拿掉这一颗)。放进去的按钮原来在
    /// 别处时两处对调;隔空播放不能因此被挤掉,也不能被换到两端。底栏「添到最后」时按钮从原处挪过来,
    /// 原处空着。颗数上限由编辑页按设备宽度管,这里不限。
    public func canPlace(_ action: NowPlayingControlAction?, at position: NowPlayingControlPosition) -> Bool {
        switch position {
        case .slot(let slot):
            guard NowPlayingControlSlot.single.contains(slot) else { return false }
            let current = actions[slot]
            guard action != current else { return true }
            if let action, slot.isTransportEdge, !action.fitsTransportEdge { return false }
            guard current?.isRequiredOnPage == true else { return true }
            // 这一格现在是隔空播放:只有新按钮原来也在页面上(而且不在两端)时,两处对调才留得住它。
            guard let action, let from = self.position(of: action) else { return false }
            if case .slot(let fromSlot) = from { return !fromSlot.isTransportEdge }
            return true
        case .bar(let index):
            guard index >= 0, index <= bar.count else { return false }
            guard index < bar.count else { return action != nil }
            let current = bar[index]
            guard action != current else { return true }
            guard let action else { return !current.isRequiredOnPage }
            switch self.position(of: action) {
            case nil: return !current.isRequiredOnPage
            case .bar: return true
            case .slot(let fromSlot): return !(current.isRequiredOnPage && fromSlot.isTransportEdge)
            }
        }
    }

    /// 放不进去时原样返回。
    public func placing(_ action: NowPlayingControlAction?, at position: NowPlayingControlPosition) -> NowPlayingControlLayout {
        guard canPlace(action, at: position), action != self.action(at: position) else { return self }
        var singles = actions
        var entries = barEntries
        let from = action.flatMap { self.position(of: $0) }
        switch position {
        case .slot(let slot):
            let displaced = singles[slot]
            switch from {
            case .slot(let fromSlot)?: singles[fromSlot] = displaced
            case .bar(let fromIndex)?: Self.replace(fromIndex, with: displaced, in: &entries)
            case nil: break
            }
            singles[slot] = action
        case .bar(let index) where index == bar.count:
            guard let action else { return self }
            switch from {
            case .slot(let fromSlot)?: singles[fromSlot] = nil
            case .bar(let fromIndex)?: Self.replace(fromIndex, with: nil, in: &entries)
            case nil: break
            }
            entries.append(BarEntry(action))
        case .bar(let index):
            let displaced = bar[index]
            switch from {
            case .slot(let fromSlot)?:
                singles[fromSlot] = displaced
                Self.replace(index, with: action, in: &entries)
            case .bar(let fromIndex)?:
                // 一排里两颗对调:先把两处的名字换过来,下标不受影响。
                Self.replace(index, with: action, in: &entries)
                Self.replace(fromIndex, with: displaced, in: &entries)
            case nil:
                Self.replace(index, with: action, in: &entries)
            }
        }
        return with(singles: singles, entries: entries)
    }

    /// 最下面那一排按编辑页列表里的位置挪动(与 `onMove` 的参数一致)。认不出的名字留在原处。
    public func movingBar(fromOffsets source: IndexSet, toOffset destination: Int) -> NowPlayingControlLayout {
        var order = bar
        let moving = source.sorted().filter { order.indices.contains($0) }.map { order[$0] }
        order = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: max(0, min(insertAt, order.count)))
        guard order != bar else { return self }
        var entries = barEntries
        var next = order.makeIterator()
        for index in entries.indices where entries[index].action != nil {
            entries[index] = BarEntry(next.next())
        }
        return with(singles: actions, entries: entries)
    }

    public func settingStatusItem(_ item: NowPlayingStatusItem, visible: Bool) -> NowPlayingControlLayout {
        var hidden = hiddenStatus.filter { $0 != item.rawValue }
        if !visible { hidden.append(item.rawValue) }
        return NowPlayingControlLayout(stored: stored, storedBar: storedBar, hiddenStatus: hidden, hiddenMenu: hiddenMenu)
    }

    public func settingMenuItem(_ item: NowPlayingMenuItem, visible: Bool) -> NowPlayingControlLayout {
        var hidden = hiddenMenu.filter { $0 != item.rawValue }
        if !visible { hidden.append(item.rawValue) }
        return NowPlayingControlLayout(stored: stored, storedBar: storedBar, hiddenStatus: hiddenStatus, hiddenMenu: hidden)
    }

    /// 「更多」里的项全部显示回来。
    public func showingAllMenuItems() -> NowPlayingControlLayout {
        var copy = self
        copy.hiddenMenu = []
        return copy
    }

    /// 换上另一份配置的按钮摆法,状态行与「更多」的开关不变(歌词界面单独摆按钮时用)。
    public func replacingActions(with other: NowPlayingControlLayout) -> NowPlayingControlLayout {
        NowPlayingControlLayout(
            stored: other.stored,
            storedBar: other.storedBar,
            hiddenStatus: hiddenStatus,
            hiddenMenu: hiddenMenu
        )
    }

    /// 只留按钮摆法,状态行与「更多」的开关回到默认。
    public var actionsOnly: NowPlayingControlLayout {
        NowPlayingControlLayout(stored: stored, storedBar: storedBar, hiddenStatus: [], hiddenMenu: [])
    }

    /// 只恢复按钮,状态行的显隐不动。
    public func resettingActions() -> NowPlayingControlLayout {
        NowPlayingControlLayout(stored: [:], storedBar: nil, hiddenStatus: hiddenStatus, hiddenMenu: hiddenMenu)
    }

    // MARK: 归一

    /// 最下面那一排存的一项:认得的按钮,或者别的版本写进来、这里认不出的名字。
    private struct BarEntry: Equatable {
        var raw: String
        var action: NowPlayingControlAction?

        init(raw: String) {
            self.raw = raw
            self.action = NowPlayingControlAction(rawValue: raw)
        }

        init(_ action: NowPlayingControlAction?) {
            self.raw = action?.rawValue ?? ""
            self.action = action
        }
    }

    /// 这一排归一之后的样子:认不出的名字留在原位,认得的只留实际摆出来的那些(重复的、被单格占了的去掉,
    /// 隔空播放补回来的也算进去)。改这一排都从它出发。
    private var barEntries: [BarEntry] {
        Self.resolve(stored: stored, storedBar: storedBar).bar
    }

    /// 第 `index` 颗(只数认得的)换成 `action`;nil 是拿掉。
    private static func replace(_ index: Int, with action: NowPlayingControlAction?, in entries: inout [BarEntry]) {
        var seen = -1
        guard let position = entries.firstIndex(where: { entry in
            guard entry.action != nil else { return false }
            seen += 1
            return seen == index
        }) else { return }
        if let action {
            entries[position] = BarEntry(action)
        } else {
            entries.remove(at: position)
        }
    }

    /// 按改好的单格与这一排重新组一份配置。单格只记和默认不同的;这一排和默认一样(也没有认不出的名字)
    /// 时不记,否则整串记下来。
    private func with(
        singles next: [NowPlayingControlSlot: NowPlayingControlAction],
        entries: [BarEntry]
    ) -> NowPlayingControlLayout {
        var stored = self.stored
        for slot in NowPlayingControlSlot.single {
            let value = next[slot]
            if value == Self.defaultActions[slot] {
                stored.removeValue(forKey: slot.rawValue)
            } else if value != actions[slot] || stored[slot.rawValue] == nil {
                stored[slot.rawValue] = value?.rawValue ?? ""
            }
        }
        var storedBar: [String]? = entries.map(\.raw)
        if entries == Self.defaultBar.map({ BarEntry($0) }) {
            storedBar = nil
        }
        if storedBar != nil || entries.map(\.action) != barEntries.map(\.action) {
            // 这一排改过(或者已经整串存着):旧版三格不再单独记,存的时候照这一串写。
            for slot in NowPlayingControlSlot.legacyBar { stored.removeValue(forKey: slot.rawValue) }
        }
        return NowPlayingControlLayout(stored: stored, storedBar: storedBar, hiddenStatus: hiddenStatus, hiddenMenu: hiddenMenu)
    }

    /// 没存的单格取默认;同一个按钮出现两次只留前面那处(单格先于底栏);隔空播放不在页面上(别处改坏、
    /// 或别的版本允许拿掉)时补进这一排的正中。
    private static func resolve(
        stored: [String: String],
        storedBar: [String]?
    ) -> (actions: [NowPlayingControlSlot: NowPlayingControlAction], bar: [BarEntry]) {
        var result: [NowPlayingControlSlot: NowPlayingControlAction] = [:]
        var seen = Set<NowPlayingControlAction>()
        for slot in NowPlayingControlSlot.single {
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
        let names = storedBar ?? NowPlayingControlSlot.legacyBar.compactMap { slot in
            let raw = stored[slot.rawValue] ?? legacyBarDefaults[slot]?.rawValue ?? ""
            return raw.isEmpty ? nil : raw
        }
        var bar: [BarEntry] = []
        for name in names where !name.isEmpty {
            let entry = BarEntry(raw: name)
            if let action = entry.action {
                guard !seen.contains(action) else { continue }
                seen.insert(action)
            }
            bar.append(entry)
        }
        if !seen.contains(.airPlay) {
            // 插在认得的那几颗正中那一颗前面:只剩歌词与队列时回到两者中间,和默认一样。
            let known = bar.indices.filter { bar[$0].action != nil }
            bar.insert(BarEntry(.airPlay), at: known.isEmpty ? bar.count : known[known.count / 2])
        }
        return (result, bar)
    }

    /// 写给旧版本看的三格:一颗放中间,两颗分两头,三颗以上取前三颗。
    private static func legacyProjection(
        of bar: [NowPlayingControlAction]
    ) -> [(NowPlayingControlSlot, NowPlayingControlAction?)] {
        switch bar.count {
        case 0: [(.barLeading, nil), (.barCenter, nil), (.barTrailing, nil)]
        case 1: [(.barLeading, nil), (.barCenter, bar[0]), (.barTrailing, nil)]
        case 2: [(.barLeading, bar[0]), (.barCenter, nil), (.barTrailing, bar[1])]
        default: [(.barLeading, bar[0]), (.barCenter, bar[1]), (.barTrailing, bar[2])]
        }
    }

    // MARK: 铺到各版面

    /// 手机横屏顶上那排圆钮:左边一组放底栏的按钮(歌词在右栏、全屏有自己那颗键,不放),
    /// 隔空播放排在这一组最后,和原来的样子一致;右边歌名旁那一格。左边一组最多 `leadingLimit` 颗,
    /// 多出来的从后往前让掉,AirPlay 不让。
    public func compactLandscapeChrome(
        leadingLimit: Int = .max
    ) -> (leading: [NowPlayingControlAction], trailing: NowPlayingControlAction?) {
        let skipped: Set<NowPlayingControlAction> = [.lyrics, .fullScreen]
        let row = bar.filter { !skipped.contains($0) }
        let airPlay = row.filter { $0 == .airPlay }
        let others = row.filter { $0 != .airPlay }.prefix(max(0, leadingLimit - airPlay.count))
        let header = actions[.header].flatMap { skipped.contains($0) ? nil : $0 }
        return (Array(others) + airPlay, header)
    }

    /// iPad 横屏左栏最下面那排:歌词常驻右栏,不放歌词键。
    public func wideLandscapeBar() -> [NowPlayingControlAction] {
        bar.filter { $0 != .lyrics }
    }

    /// iPhone Duo 竖栏那一列:中间一组(底栏里除 AirPlay 外的按钮,最多 `middleLimit` 颗)和下面一组里歌名旁那一格。
    public func toolColumnGroups(
        middleLimit: Int = .max
    ) -> (middle: [NowPlayingControlAction], header: NowPlayingControlAction?) {
        let middle = Array(bar.filter { $0 != .airPlay }.prefix(max(0, middleLimit)))
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
            visible.formUnion(bar)
            if let header = actions[.header] { visible.insert(header) }
        case .compactLandscape(_, let leadingLimit):
            let chrome = compactLandscapeChrome(leadingLimit: leadingLimit)
            visible.formUnion(chrome.leading)
            if let trailing = chrome.trailing { visible.insert(trailing) }
        case .wideLandscape:
            visible.formUnion(wideLandscapeBar())
            if let header = actions[.header] { visible.insert(header) }
        case .toolColumn(_, let headerOverflows, let middleLimit):
            let groups = toolColumnGroups(middleLimit: middleLimit)
            visible.formUnion(groups.middle)
            if let header = groups.header, !headerOverflows { visible.insert(header) }
        case .immersiveLyrics:
            if let action = immersiveLyricsAction() { visible.insert(action) }
        case .portraitLyrics(let headerExtra):
            visible.formUnion(bar)
            if let header = actions[.header] { visible.insert(header) }
            if let headerExtra { visible.insert(headerExtra) }
        case .configuredImmersiveLyrics(let configured):
            visible.formUnion(configured)
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
