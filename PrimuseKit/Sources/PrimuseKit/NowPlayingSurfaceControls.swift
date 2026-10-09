import Foundation

// 播放页除了竖屏封面那一页,还有歌词、全屏歌词、全屏效果和电台几种界面,各有几个能换按钮的位置。
// 每种界面一个存储键(经 iCloud 同步):旧版本只认原来那份配置,改它时不会把这里的字段抹掉。
// 没改过的界面存空串,和这个功能出现之前一模一样。

// MARK: - 歌词界面

/// 竖屏看歌词时(歌词顶替封面)的按钮:默认和封面界面同一组,也可以单独摆;歌词页顶上歌名旁多一格
/// (原来自动出现的卡拉OK键);上滑歌词时要不要收起播放控件。状态行与「更多」的开关仍跟封面那份。
public struct NowPlayingLyricsPageControls: Equatable, Sendable {
    public static let storageKey = "primuse.player.controls.music.lyrics.v1"
    /// 歌词页顶上多出来那一格默认放卡拉OK,和这个功能出现之前一样。
    public static let defaultHeaderExtra: NowPlayingControlAction = .karaoke

    public static let `default` = NowPlayingLyricsPageControls(
        usesOwnButtons: false,
        ownStorage: nil,
        headerExtraRaw: nil,
        collapsesControlsOnScroll: true
    )

    public private(set) var usesOwnButtons: Bool
    /// 单独摆的那组按钮(`NowPlayingControlLayout` 的存储串)。nil 是从没单独摆过:打开时从封面那组抄一份。
    private var ownStorage: String?
    /// nil 用默认(卡拉OK),空串是故意空着,其余是按钮名(认不出的原样保留)。
    private var headerExtraRaw: String?
    public private(set) var collapsesControlsOnScroll: Bool

    private init(
        usesOwnButtons: Bool,
        ownStorage: String?,
        headerExtraRaw: String?,
        collapsesControlsOnScroll: Bool
    ) {
        self.usesOwnButtons = usesOwnButtons
        self.ownStorage = ownStorage
        self.headerExtraRaw = headerExtraRaw
        self.collapsesControlsOnScroll = collapsesControlsOnScroll
    }

    private struct Stored: Codable {
        var own: Bool?
        var slots: String?
        var extra: String?
        var collapses: Bool?
    }

    public static func decode(_ rawValue: String) -> NowPlayingLyricsPageControls {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        return NowPlayingLyricsPageControls(
            usesOwnButtons: stored.own ?? false,
            ownStorage: stored.slots,
            headerExtraRaw: stored.extra,
            collapsesControlsOnScroll: stored.collapses ?? true
        )
    }

    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            own: usesOwnButtons ? true : nil,
            slots: ownStorage,
            extra: headerExtraRaw,
            collapses: collapsesControlsOnScroll ? nil : false
        )
        return NowPlayingSurfaceStorage.encode(stored)
    }

    public var isDefault: Bool { self == .default }

    /// 单独摆的那组按钮;没单独摆过时是默认摆法。
    public var ownButtons: NowPlayingControlLayout {
        NowPlayingControlLayout.decode(ownStorage ?? "")
    }

    public var headerExtra: NowPlayingControlAction? {
        guard let headerExtraRaw else { return Self.defaultHeaderExtra }
        return NowPlayingControlAction(rawValue: headerExtraRaw)
    }

    /// 歌词界面实际用的配置:单独摆了按钮就换上那组,状态行与「更多」的开关跟封面那份。
    public func resolvedLayout(cover: NowPlayingControlLayout) -> NowPlayingControlLayout {
        usesOwnButtons ? cover.replacingActions(with: ownButtons) : cover
    }

    /// 歌词页顶上多出来那一格能放什么:隔空播放不放这里(它必须留在六个位置里),
    /// 歌词键在歌词页上就是「回到封面」,顶上的小封面已经管这件事。
    public static func allowsHeaderExtra(_ action: NowPlayingControlAction) -> Bool {
        action != .airPlay && action != .lyrics
    }

    /// 打开单独设置时从封面那组抄一份起步(之前单独摆过就接着用那一份)。
    public func settingUsesOwnButtons(_ uses: Bool, cover: NowPlayingControlLayout) -> NowPlayingLyricsPageControls {
        var copy = self
        copy.usesOwnButtons = uses
        if uses, ownStorage == nil {
            copy.ownStorage = cover.actionsOnly.encoded()
        }
        return copy
    }

    public func placingOwnButton(
        _ action: NowPlayingControlAction?,
        in slot: NowPlayingControlSlot
    ) -> NowPlayingLyricsPageControls {
        var copy = self
        copy.ownStorage = ownButtons.placing(action, in: slot).encoded()
        return copy
    }

    public func settingHeaderExtra(_ action: NowPlayingControlAction?) -> NowPlayingLyricsPageControls {
        if let action, !Self.allowsHeaderExtra(action) { return self }
        var copy = self
        copy.headerExtraRaw = action == Self.defaultHeaderExtra ? nil : (action?.rawValue ?? "")
        return copy
    }

    public func settingCollapsesControlsOnScroll(_ collapses: Bool) -> NowPlayingLyricsPageControls {
        var copy = self
        copy.collapsesControlsOnScroll = collapses
        return copy
    }
}

// MARK: - 全屏歌词

/// 全屏歌词(以及 iPad 横屏看歌词)上能换按钮的四个位置。
public enum NowPlayingImmersiveLyricsSlot: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// 顶上一排「更多」左边两格。第一格默认和封面界面歌名旁那一格一样(原来心形的位置)。
    case topPrimary
    case topSecondary
    /// 底部播放条播放键两侧。
    case dockLeading
    case dockTrailing

    public var id: String { rawValue }

    public var isDockEdge: Bool { self == .dockLeading || self == .dockTrailing }
}

/// 一格里放什么。
public enum NowPlayingSlotChoice: Hashable, Sendable {
    /// 和封面界面歌名旁那一格一样。
    case followHeader
    case action(NowPlayingControlAction)
    case empty

    public var pickedAction: NowPlayingControlAction? {
        if case .action(let action) = self { return action }
        return nil
    }
}

public struct NowPlayingImmersiveLyricsControls: Equatable, Sendable {
    public typealias Slot = NowPlayingImmersiveLyricsSlot

    public static let storageKey = "primuse.player.controls.music.immersiveLyrics.v1"
    public static let `default` = NowPlayingImmersiveLyricsControls(stored: [:])

    private static let followHeaderToken = "@header"
    private static let defaultChoices: [Slot: NowPlayingSlotChoice] = [.topPrimary: .followHeader]

    /// 位置 → 存下来的值:「@header」是跟歌名旁那一格,空串是故意空着,其余是按钮名。只记和默认不同的格。
    private var stored: [String: String]

    private init(stored: [String: String]) {
        self.stored = stored
    }

    public static func decode(_ rawValue: String) -> NowPlayingImmersiveLyricsControls {
        NowPlayingImmersiveLyricsControls(stored: NowPlayingSurfaceStorage.decodeSlots(rawValue))
    }

    public func encoded() -> String {
        NowPlayingSurfaceStorage.encodeSlots(stored)
    }

    public var isDefault: Bool { stored.isEmpty }

    public func choice(in slot: Slot) -> NowPlayingSlotChoice {
        guard let raw = stored[slot.rawValue] else { return Self.defaultChoices[slot] ?? .empty }
        if raw == Self.followHeaderToken { return .followHeader }
        return NowPlayingControlAction(rawValue: raw).map(NowPlayingSlotChoice.action) ?? .empty
    }

    /// 全屏歌词上不放的按钮:歌词就在眼前,全屏键在这里是「退出全屏」那颗。
    public static func allows(_ action: NowPlayingControlAction) -> Bool {
        action != .lyrics && action != .fullScreen
    }

    /// 「跟歌名旁那一格」只给顶上的格:底部两侧是随机、循环这类开关的位置。
    public static func allowsFollowingHeader(in slot: Slot) -> Bool {
        !slot.isDockEdge
    }

    /// 歌名旁那一格放到全屏歌词上是什么(全屏歌词不放歌词、全屏键,隔空播放也不跟过来)。
    public static func followedHeaderAction(_ header: NowPlayingControlAction?) -> NowPlayingControlAction? {
        header.flatMap { [.lyrics, .fullScreen, .airPlay].contains($0) ? nil : $0 }
    }

    /// 各格此刻实际摆的按钮。同一个按钮出现两次只留前面那格(顶上先于底部)。
    public func actions(header: NowPlayingControlAction?) -> [Slot: NowPlayingControlAction] {
        var result: [Slot: NowPlayingControlAction] = [:]
        var seen = Set<NowPlayingControlAction>()
        for slot in Slot.allCases {
            let action: NowPlayingControlAction?
            switch choice(in: slot) {
            case .followHeader: action = Self.followedHeaderAction(header)
            case .action(let picked): action = Self.allows(picked) ? picked : nil
            case .empty: action = nil
            }
            guard let action, !seen.contains(action) else { continue }
            seen.insert(action)
            result[slot] = action
        }
        return result
    }

    public func canPlace(_ choice: NowPlayingSlotChoice, in slot: Slot) -> Bool {
        switch choice {
        case .followHeader: Self.allowsFollowingHeader(in: slot)
        case .action(let action): Self.allows(action)
        case .empty: true
        }
    }

    /// 放不进去时原样返回。按钮原来在别的格(明确放的,不算「跟歌名旁」)时两格对调。
    /// 只改动到的格,别的格里认不出的名字原样留着。
    public func placing(_ choice: NowPlayingSlotChoice, in slot: Slot) -> NowPlayingImmersiveLyricsControls {
        guard canPlace(choice, in: slot) else { return self }
        var stored = self.stored
        if case .action = choice,
           let from = Slot.allCases.first(where: { $0 != slot && self.choice(in: $0) == choice }) {
            let displaced = self.choice(in: slot)
            let moved = displaced == .followHeader && !Self.allowsFollowingHeader(in: from) ? .empty : displaced
            Self.store(moved, in: from, into: &stored)
        }
        Self.store(choice, in: slot, into: &stored)
        return NowPlayingImmersiveLyricsControls(stored: stored)
    }

    private static func store(_ choice: NowPlayingSlotChoice, in slot: Slot, into stored: inout [String: String]) {
        guard choice != (defaultChoices[slot] ?? .empty) else {
            stored.removeValue(forKey: slot.rawValue)
            return
        }
        switch choice {
        case .followHeader: stored[slot.rawValue] = followHeaderToken
        case .action(let action): stored[slot.rawValue] = action.rawValue
        case .empty: stored[slot.rawValue] = ""
        }
    }
}

// MARK: - 全屏效果

/// 全屏效果播放页上能换按钮的位置。
public enum NowPlayingEffectPlayerSlot: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    /// 右上角(原来的队列键)。
    case topTrailing
    /// 底部播放胶囊里播放键两侧。
    case pillLeading
    case pillTrailing

    public var id: String { rawValue }
}

public struct NowPlayingEffectPlayerControls: Equatable, Sendable {
    public typealias Slot = NowPlayingEffectPlayerSlot

    public static let storageKey = "primuse.player.controls.music.fullscreenEffect.v1"
    public static let `default` = NowPlayingEffectPlayerControls(stored: [:])
    private static let defaultActions: [Slot: NowPlayingControlAction] = [.topTrailing: .queue]

    /// 全屏效果页上能放的。这一页没有「更多」,歌词、全屏、卡拉OK、投放这类会换走整页的不放。
    public static let allowedActions: [NowPlayingControlAction] = [
        .like, .dislike, .queue, .shuffle, .repeatMode, .sleepTimer,
        .airPlay, .equalizer, .playbackSpeed, .addToPlaylist, .share,
    ]

    private var stored: [String: String]

    private init(stored: [String: String]) {
        self.stored = stored
    }

    public static func decode(_ rawValue: String) -> NowPlayingEffectPlayerControls {
        NowPlayingEffectPlayerControls(stored: NowPlayingSurfaceStorage.decodeSlots(rawValue))
    }

    public func encoded() -> String {
        NowPlayingSurfaceStorage.encodeSlots(stored)
    }

    public var isDefault: Bool { stored.isEmpty }

    public static func allows(_ action: NowPlayingControlAction) -> Bool {
        allowedActions.contains(action)
    }

    /// 各格实际摆的按钮。同一个按钮出现两次只留前面那格。
    public var actions: [Slot: NowPlayingControlAction] {
        var result: [Slot: NowPlayingControlAction] = [:]
        var seen = Set<NowPlayingControlAction>()
        for slot in Slot.allCases {
            guard let action = storedAction(in: slot), Self.allows(action), !seen.contains(action) else { continue }
            seen.insert(action)
            result[slot] = action
        }
        return result
    }

    public func action(in slot: Slot) -> NowPlayingControlAction? {
        actions[slot]
    }

    private func storedAction(in slot: Slot) -> NowPlayingControlAction? {
        guard let raw = stored[slot.rawValue] else { return Self.defaultActions[slot] }
        return NowPlayingControlAction(rawValue: raw)
    }

    /// 放不进去时原样返回;按钮原来在别的格时两格对调。只改动到的格,别的格里认不出的名字原样留着。
    public func placing(_ action: NowPlayingControlAction?, in slot: Slot) -> NowPlayingEffectPlayerControls {
        if let action, !Self.allows(action) { return self }
        var stored = self.stored
        if let action, let from = Slot.allCases.first(where: { $0 != slot && storedAction(in: $0) == action }) {
            Self.store(storedAction(in: slot), in: from, into: &stored)
        }
        Self.store(action, in: slot, into: &stored)
        return NowPlayingEffectPlayerControls(stored: stored)
    }

    private static func store(_ action: NowPlayingControlAction?, in slot: Slot, into stored: inout [String: String]) {
        if action == defaultActions[slot] {
            stored.removeValue(forKey: slot.rawValue)
        } else {
            stored[slot.rawValue] = action?.rawValue ?? ""
        }
    }
}

// MARK: - 电台

/// 电台播放页最下面那一排。rawValue 会写进配置并经 iCloud 同步,发布后不能改名。
public enum NowPlayingRadioControlItem: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case airPlay
    /// 码率、格式那行小字。
    case info
    case share
    /// 这个台听过的歌(电台详情)。
    case history
    case sleepTimer

    public var id: String { rawValue }

    /// 隔空播放是系统那颗必须直接点的按钮,电台页又没有「更多」,不能藏。
    public var isRequired: Bool { self == .airPlay }
}

/// 电台播放页最下面那一排的顺序与显隐,以及要不要显示音量条。
public struct NowPlayingRadioControlLayout: Equatable, Sendable {
    public typealias Item = NowPlayingRadioControlItem

    public static let storageKey = "primuse.player.controls.radio.v1"
    public static let defaultOrder: [Item] = Item.allCases
    public static let `default` = NowPlayingRadioControlLayout(order: defaultOrder, hidden: [], showsVolumeBar: true)

    /// 全部项,按用户排的顺序(含藏起来的)。
    public private(set) var order: [Item]
    public private(set) var hidden: Set<Item>
    public private(set) var showsVolumeBar: Bool

    private init(order: [Item], hidden: Set<Item>, showsVolumeBar: Bool) {
        self.order = Self.completedOrder(order)
        self.hidden = hidden.filter { !$0.isRequired }
        self.showsVolumeBar = showsVolumeBar
    }

    private struct Stored: Codable {
        var order: [String]?
        var hidden: [String]?
        var showsVolumeBar: Bool?
    }

    public static func decode(_ rawValue: String) -> NowPlayingRadioControlLayout {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            return .default
        }
        return NowPlayingRadioControlLayout(
            order: (stored.order ?? []).compactMap(Item.init(rawValue:)),
            hidden: Set((stored.hidden ?? []).compactMap(Item.init(rawValue:))),
            showsVolumeBar: stored.showsVolumeBar ?? true
        )
    }

    public func encoded() -> String {
        guard !isDefault else { return "" }
        let stored = Stored(
            order: order == Self.defaultOrder ? nil : order.map(\.rawValue),
            hidden: hidden.isEmpty ? nil : order.filter { hidden.contains($0) }.map(\.rawValue),
            showsVolumeBar: showsVolumeBar ? nil : false
        )
        return NowPlayingSurfaceStorage.encode(stored)
    }

    public var isDefault: Bool { self == .default }

    public func isShown(_ item: Item) -> Bool { !hidden.contains(item) }

    /// 页面上按顺序摆哪几项。
    public var visibleItems: [Item] { order.filter(isShown) }

    public func settingItem(_ item: Item, shown: Bool) -> NowPlayingRadioControlLayout {
        guard !item.isRequired else { return self }
        var copy = self
        if shown { copy.hidden.remove(item) } else { copy.hidden.insert(item) }
        return copy
    }

    /// 按编辑页列表里的位置挪动(与 `onMove` 的参数一致)。
    public func movingItems(fromOffsets source: IndexSet, toOffset destination: Int) -> NowPlayingRadioControlLayout {
        var copy = self
        let moving = source.sorted().map { order[$0] }
        var remaining = order.enumerated().filter { !source.contains($0.offset) }.map(\.element)
        let insertAt = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: max(0, min(insertAt, remaining.count)))
        copy.order = remaining
        return copy
    }

    public func settingShowsVolumeBar(_ shows: Bool) -> NowPlayingRadioControlLayout {
        var copy = self
        copy.showsVolumeBar = shows
        return copy
    }

    /// 去掉重复,缺的(新版本才加的项)插回它在默认顺序里的前一项后面。
    private static func completedOrder(_ order: [Item]) -> [Item] {
        var result: [Item] = []
        for item in order where !result.contains(item) {
            result.append(item)
        }
        for (index, item) in defaultOrder.enumerated() where !result.contains(item) {
            let previous = defaultOrder[..<index].last { result.contains($0) }
            let position = previous.flatMap { result.firstIndex(of: $0) }.map { $0 + 1 } ?? 0
            result.insert(item, at: position)
        }
        return result
    }
}

// MARK: - 文字稿

/// 有声书、播客看文字稿时上滑要不要收起播放控件(音乐歌词的开关在 `NowPlayingLyricsPageControls` 里)。
public enum NowPlayingTextScrollPreference {
    public static let collapsesByDefault = true

    public static func collapsesKey(for kind: SpokenWordPlayerKind) -> String {
        "primuse.player.text.collapsesOnScroll.\(kind.rawValue).v1"
    }
}

// MARK: - 存取

enum NowPlayingSurfaceStorage {
    private struct SlotsPayload: Codable {
        var slots: [String: String]
    }

    /// 键按字母排,同样的配置每次编出同一个字符串,同步那边不会误以为变了。
    static func encode<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decodeSlots(_ rawValue: String) -> [String: String] {
        guard !rawValue.isEmpty,
              let data = rawValue.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SlotsPayload.self, from: data) else {
            return [:]
        }
        return payload.slots
    }

    static func encodeSlots(_ slots: [String: String]) -> String {
        slots.isEmpty ? "" : encode(SlotsPayload(slots: slots))
    }
}
