import Foundation

/// 播放页「转轮」里播放器两侧的一面。播放器本身永远在中间,不在这里面。
///
/// 每一面按「用途」把几样功能排成一页卡片:调音管这首歌听起来怎样,发现从这首歌出发,
/// 接下来管怎么往下放,舞台换个方式听。只在 iPhone / iPad 的音乐播放页上出现;macOS 与 tvOS 不做转轮。
public enum NowPlayingCarouselPanel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 调音:均衡器、音效、速度与音调、输出与音质。
    case sound
    /// 发现:专辑、艺人、相似歌曲。
    case explore
    /// 接下来:播放方式与播放队列。
    case upNext
    /// 舞台:卡拉 OK 与全屏效果。
    case stage

    public var id: String { rawValue }

    /// 这一面能放的卡片,按面里从上到下的顺序。
    public var cards: [NowPlayingCarouselCard] {
        NowPlayingCarouselCard.allCases.filter { $0.panel == self }
    }

    /// 旧版六个单功能页的存储名并进哪一面(配置升级用)。不认识的返回 nil。
    public static func migrated(legacyName: String) -> NowPlayingCarouselPanel? {
        switch legacyName {
        case "equalizer", "audioEffects": .sound
        case "similarSongs", "albumAndArtist": .explore
        case "queue": .upNext
        case "karaoke": .stage
        default: nil
        }
    }
}

/// 面里的一张卡片。用户可以在设置里逐张关掉;当前这首用不了的(比如 Apple Music 曲目没有均衡器)
/// 也不出现。
public enum NowPlayingCarouselCard: String, CaseIterable, Codable, Sendable, Identifiable {
    case equalizer
    case audioEffects
    case speedAndPitch
    case outputAndQuality
    case album
    case artist
    case similarSongs
    case playbackModes
    case queue
    case karaoke
    case fullscreenEffects

    public var id: String { rawValue }

    public var panel: NowPlayingCarouselPanel {
        switch self {
        case .equalizer, .audioEffects, .speedAndPitch, .outputAndQuality: .sound
        case .album, .artist, .similarSongs: .explore
        case .playbackModes, .queue: .upNext
        case .karaoke, .fullscreenEffects: .stage
        }
    }

    /// 当前这首能不能用这张卡。和播放页「更多」菜单的取舍一致:Apple Music 由系统播放器出声、
    /// 投放时由对方设备出声,都不经过本机的均衡器与音效;Apple Music 也不给速度、音调和卡拉 OK。
    public func isAvailable(in context: NowPlayingCarouselCardContext) -> Bool {
        switch self {
        case .equalizer, .audioEffects:
            !context.isAppleMusic && !context.isCasting
        case .speedAndPitch, .karaoke:
            !context.isAppleMusic
        case .outputAndQuality, .album, .artist, .similarSongs, .playbackModes, .queue, .fullscreenEffects:
            true
        }
    }
}

/// 判断卡片能不能用时看的那几样播放状态。
public struct NowPlayingCarouselCardContext: Equatable, Sendable {
    public var isAppleMusic: Bool
    public var isCasting: Bool

    public init(isAppleMusic: Bool = false, isCasting: Bool = false) {
        self.isAppleMusic = isAppleMusic
        self.isCasting = isCasting
    }
}

/// 设置里逐张关掉的卡片。存的是关掉的那几张(逗号分隔),默认全开,以后新加的卡也默认开着。
public struct NowPlayingCarouselCardSettings: Equatable, Sendable {
    public static let storageKey = "primuse.player.carousel.hiddenCards"

    public private(set) var hidden: Set<NowPlayingCarouselCard>

    public init(hidden: Set<NowPlayingCarouselCard> = []) {
        self.hidden = hidden
    }

    public static func decode(_ storage: String) -> NowPlayingCarouselCardSettings {
        let cards = storage.split(separator: ",").compactMap {
            NowPlayingCarouselCard(rawValue: $0.trimmingCharacters(in: .whitespaces))
        }
        return NowPlayingCarouselCardSettings(hidden: Set(cards))
    }

    /// 按卡片的固定顺序写,同样的设置总是同一行文本(备份、同步比对不会误判有改动)。
    public var storageValue: String {
        NowPlayingCarouselCard.allCases.filter(hidden.contains).map(\.rawValue).joined(separator: ",")
    }

    public var isDefault: Bool { hidden.isEmpty }

    public func isEnabled(_ card: NowPlayingCarouselCard) -> Bool {
        !hidden.contains(card)
    }

    public mutating func setEnabled(_ enabled: Bool, for card: NowPlayingCarouselCard) {
        if enabled {
            hidden.remove(card)
        } else {
            hidden.insert(card)
        }
    }

    /// 这一面此刻要画的卡片:用户开着、当前这首也用得了的。
    public func visibleCards(
        on panel: NowPlayingCarouselPanel,
        in context: NowPlayingCarouselCardContext
    ) -> [NowPlayingCarouselCard] {
        panel.cards.filter { isEnabled($0) && $0.isAvailable(in: context) }
    }
}

/// 转轮的排布:播放器左边几面、右边几面。两边的数组都是**从播放器往外数**,第一个紧挨着播放器。
///
/// 一面只能出现一次;每边最多 `maximumPanelsPerSide` 面。存成一行文本 `左|右`
/// (如 `sound,explore|upNext,stage`),读到不认识的名字直接丢掉,不让整份配置失效。
/// 旧版六个单功能页的名字按 `NowPlayingCarouselPanel.migrated(legacyName:)` 并进对应的面,
/// 左右归属与先后不变,并完重复的只留先出现的那一个。
public struct NowPlayingCarouselConfiguration: Equatable, Sendable {
    public enum Side: String, CaseIterable, Sendable {
        case leading
        case trailing
    }

    /// 转轮总开关。默认关:打开之前播放页的左右滑动不做任何事。
    public static let enabledStorageKey = "primuse.player.carousel.enabled"
    public static let enabledByDefault = false
    /// 两边各放哪几面。
    public static let storageKey = "primuse.player.carousel.layout"
    public static let maximumPanelsPerSide = 4

    public static let `default` = NowPlayingCarouselConfiguration(
        leading: [.sound, .explore],
        trailing: [.upNext, .stage]
    )

    public private(set) var leading: [NowPlayingCarouselPanel]
    public private(set) var trailing: [NowPlayingCarouselPanel]

    public init(leading: [NowPlayingCarouselPanel], trailing: [NowPlayingCarouselPanel]) {
        var seen = Set<NowPlayingCarouselPanel>()
        self.leading = Self.normalized(leading, seen: &seen)
        self.trailing = Self.normalized(trailing, seen: &seen)
    }

    private static func normalized(
        _ panels: [NowPlayingCarouselPanel],
        seen: inout Set<NowPlayingCarouselPanel>
    ) -> [NowPlayingCarouselPanel] {
        var result: [NowPlayingCarouselPanel] = []
        for panel in panels where result.count < maximumPanelsPerSide && seen.insert(panel).inserted {
            result.append(panel)
        }
        return result
    }

    // MARK: 读写

    /// 空字符串(从没改过)用默认排布;其余按存下来的来,两边都空也照存(用户就是想全部拿掉)。
    public static func decode(_ storage: String) -> NowPlayingCarouselConfiguration {
        let trimmed = storage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.contains("|") else { return .default }
        let halves = trimmed.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        func panels(_ text: Substring?) -> [NowPlayingCarouselPanel] {
            guard let text else { return [] }
            return text.split(separator: ",").compactMap {
                let name = $0.trimmingCharacters(in: .whitespaces)
                return NowPlayingCarouselPanel(rawValue: name) ?? NowPlayingCarouselPanel.migrated(legacyName: name)
            }
        }
        return NowPlayingCarouselConfiguration(
            leading: panels(halves.first),
            trailing: panels(halves.count > 1 ? halves[1] : nil)
        )
    }

    public var storageValue: String {
        leading.map(\.rawValue).joined(separator: ",") + "|" + trailing.map(\.rawValue).joined(separator: ",")
    }

    // MARK: 查询

    public func panels(on side: Side) -> [NowPlayingCarouselPanel] {
        side == .leading ? leading : trailing
    }

    public func side(of panel: NowPlayingCarouselPanel) -> Side? {
        if leading.contains(panel) { return .leading }
        if trailing.contains(panel) { return .trailing }
        return nil
    }

    /// 还没放进转轮的面,按枚举顺序。
    public var unassigned: [NowPlayingCarouselPanel] {
        NowPlayingCarouselPanel.allCases.filter { side(of: $0) == nil }
    }

    public var isEmpty: Bool { leading.isEmpty && trailing.isEmpty }

    public func canAdd(to side: Side) -> Bool {
        panels(on: side).count < Self.maximumPanelsPerSide
    }

    /// 屏幕上从左到右的页序(左右以从左往右的书写方向为准;从右往左的语言由界面镜像)。
    public var pages: [NowPlayingCarouselPage] {
        leading.reversed().map(NowPlayingCarouselPage.panel) + [.player] + trailing.map(NowPlayingCarouselPage.panel)
    }

    /// 播放器在 `pages` 里的下标。
    public var playerPageIndex: Int { leading.count }

    /// 这一刻转得到的排布:当前这首一张卡都没有的面临时跳过,其余顺序不变。只用来画,不写回存储。
    public func skippingPanels(where isEmpty: (NowPlayingCarouselPanel) -> Bool) -> NowPlayingCarouselConfiguration {
        NowPlayingCarouselConfiguration(
            leading: leading.filter { !isEmpty($0) },
            trailing: trailing.filter { !isEmpty($0) }
        )
    }

    // MARK: 编辑

    /// 把一面放到某一边的 `index`(越界就放到最外面)。原来在哪儿都先拿走;那一边满了就不动。
    public mutating func insert(_ panel: NowPlayingCarouselPanel, on side: Side, at index: Int? = nil) {
        var leading = self.leading.filter { $0 != panel }
        var trailing = self.trailing.filter { $0 != panel }
        let target = side == .leading ? leading : trailing
        guard target.count < Self.maximumPanelsPerSide else { return }
        let position = min(max(index ?? target.count, 0), target.count)
        if side == .leading {
            leading.insert(panel, at: position)
        } else {
            trailing.insert(panel, at: position)
        }
        self = NowPlayingCarouselConfiguration(leading: leading, trailing: trailing)
    }

    public mutating func remove(_ panel: NowPlayingCarouselPanel) {
        self = NowPlayingCarouselConfiguration(
            leading: leading.filter { $0 != panel },
            trailing: trailing.filter { $0 != panel }
        )
    }

    /// 同一边里换顺序,语义同 `Array.move(fromOffsets:toOffset:)`。
    public mutating func move(on side: Side, fromOffsets source: IndexSet, toOffset destination: Int) {
        var panels = panels(on: side)
        let moving = source.sorted().filter { panels.indices.contains($0) }.map { panels[$0] }
        guard !moving.isEmpty else { return }
        let removedBefore = source.filter { $0 < destination }.count
        panels.removeAll { moving.contains($0) }
        let position = min(max(destination - removedBefore, 0), panels.count)
        panels.insert(contentsOf: moving, at: position)
        self = side == .leading
            ? NowPlayingCarouselConfiguration(leading: panels, trailing: trailing)
            : NowPlayingCarouselConfiguration(leading: leading, trailing: panels)
    }
}

public enum NowPlayingCarouselPage: Hashable, Sendable {
    case player
    case panel(NowPlayingCarouselPanel)

    public var panel: NowPlayingCarouselPanel? {
        if case .panel(let panel) = self { return panel }
        return nil
    }
}

/// 转轮手势与翻页的纯规则。和 SwiftUI 无关,好单测。
public enum NowPlayingCarouselPolicy {
    public enum Axis: Equatable, Sendable {
        case horizontal
        case rejected
    }

    /// 认方向前手指至少要挪这么远。
    public static let recognitionDistance = 10.0
    /// 横向位移要比纵向大这么多倍才算翻页,斜着拉、往下拉收起都不抢。
    public static let horizontalDominance = 1.25
    /// 松手时拖过一页宽的这么多就翻过去。
    public static let commitFraction = 0.28
    /// 或者按惯性预计能滑过这么多。
    public static let predictedCommitFraction = 0.5

    /// 一次拖动认一次方向,认定后直到松手都不改。还看不出来时返回 nil。
    public static func recognizedAxis(translationX: Double, translationY: Double) -> Axis? {
        let dx = abs(translationX)
        let dy = abs(translationY)
        guard max(dx, dy) >= recognitionDistance else { return nil }
        return dx > dy * horizontalDominance ? .horizontal : .rejected
    }

    /// 松手后停在哪一页:一次最多翻一页。`translation` 为正表示手指往右(去左边那页)。
    public static func settledIndex(
        current: Int,
        translation: Double,
        predictedEndTranslation: Double,
        pageWidth: Double,
        pageCount: Int
    ) -> Int {
        guard pageCount > 0 else { return 0 }
        let current = min(max(current, 0), pageCount - 1)
        guard pageWidth > 0 else { return current }
        let moved = -translation / pageWidth
        let predicted = -predictedEndTranslation / pageWidth
        var step = 0
        if moved >= commitFraction || predicted >= predictedCommitFraction {
            step = 1
        } else if moved <= -commitFraction || predicted <= -predictedCommitFraction {
            step = -1
        }
        // 往一边拖、又往回甩时以松手那一下的方向为准。
        if step == 1, predicted < -predictedCommitFraction * 0.5 { step = 0 }
        if step == -1, predicted > predictedCommitFraction * 0.5 { step = 0 }
        return min(max(current + step, 0), pageCount - 1)
    }

    /// 拖动中整轮的位置(以页为单位,可以是小数)。两端再往外拖有阻尼,最多露出小半页。
    public static func position(
        current: Int,
        translation: Double,
        pageWidth: Double,
        pageCount: Int
    ) -> Double {
        guard pageCount > 0 else { return 0 }
        let current = Double(min(max(current, 0), pageCount - 1))
        guard pageWidth > 0 else { return current }
        let raw = current - translation / pageWidth
        let upper = Double(pageCount - 1)
        if raw < 0 { return -rubberBand(-raw) }
        if raw > upper { return upper + rubberBand(raw - upper) }
        return raw
    }

    private static func rubberBand(_ overshoot: Double) -> Double {
        let limit = 0.22
        return limit * (1 - 1 / (overshoot * 0.55 / limit + 1))
    }

    /// 某一页相对当前位置的偏移(-1…1 之间时露在屏幕上)。
    public static func relativeOffset(pageIndex: Int, position: Double) -> Double {
        Double(pageIndex) - position
    }

    /// 当前位置下要画出来的页:停稳时只有一页,拖动 / 转动途中是相邻两页。
    public static func visiblePageIndices(position: Double, pageCount: Int) -> ClosedRange<Int> {
        guard pageCount > 0 else { return 0...0 }
        let lower = min(max(Int(position.rounded(.down)), 0), pageCount - 1)
        let upper = min(max(Int(position.rounded(.up)), 0), pageCount - 1)
        return min(lower, upper)...max(lower, upper)
    }

    /// 顶上转盘的「完整程度」:0 时只在播放器把手两边淡淡地露出几个小图标,1 时是一整条胶囊。
    /// 离开播放器那一面不到半页就长全。
    public static func dialChrome(position: Double, playerIndex: Int) -> Double {
        min(max(abs(position - Double(playerIndex)) * 2.5, 0), 1)
    }
}

// MARK: - 全屏

/// 从某一面进全屏时去哪儿。
public enum NowPlayingCarouselFullscreenDestination: Equatable, Sendable {
    /// 播放器那一面:照原来的全屏入口走(用户选定的效果,原生效果时是全屏歌词)。
    case playerDefault
    /// 临时以这一种全屏效果进全屏,不改用户选定的效果。值是效果的存储值。
    case effect(String)
    /// 用户选定的那一种全屏效果。
    case selectedEffect
    /// 卡拉 OK 的全屏舞台。
    case karaokeStage
    /// 整屏打开当前这首的专辑(和播放页「转到专辑」同一条路)。
    case albumPage
    /// 没有专辑时整屏打开艺人。
    case artistPage
}

/// 每一面进全屏(标题栏的展开键、双指张开、转横屏)各去哪儿。
public enum NowPlayingCarouselFullscreenPolicy {
    /// 调音那一面进的频谱效果(「频谱地平线」)。
    public static let spectrumEffectID = "spectrumHorizon"
    /// 接下来那一面进的封面流:两侧排着的就是播放队列。
    public static let queueEffectID = "albumFlow"
    /// 双指张开到这么大(相对按下时)才进全屏。
    public static let pinchCommitScale = 1.22

    public static func destination(
        for page: NowPlayingCarouselPage,
        karaokeAvailable: Bool,
        hasAlbum: Bool,
        hasArtist: Bool
    ) -> NowPlayingCarouselFullscreenDestination {
        switch page {
        case .player:
            return .playerDefault
        case .panel(.sound):
            return .effect(spectrumEffectID)
        case .panel(.upNext):
            return .effect(queueEffectID)
        case .panel(.stage):
            return karaokeAvailable ? .karaokeStage : .selectedEffect
        case .panel(.explore):
            if hasAlbum { return .albumPage }
            return hasArtist ? .artistPage : .selectedEffect
        }
    }

    /// 转横屏时去哪儿:只在打开了「转横屏自动进全屏」时才进,停在哪一面就去那一面的去向。
    /// 设置关着时返回 nil(横屏行为不变)。
    public static func landscapeDestination(
        for page: NowPlayingCarouselPage,
        entersFullscreenInLandscape: Bool,
        karaokeAvailable: Bool,
        hasAlbum: Bool,
        hasArtist: Bool
    ) -> NowPlayingCarouselFullscreenDestination? {
        guard entersFullscreenInLandscape else { return nil }
        return destination(for: page, karaokeAvailable: karaokeAvailable, hasAlbum: hasAlbum, hasArtist: hasArtist)
    }

    /// 双指张开够不够进全屏。
    public static func pinchCommits(magnification: Double) -> Bool {
        magnification.isFinite && magnification >= pinchCommitScale
    }
}

/// 舞台那一面「全屏效果」一排缩略卡放哪几种:当前选定的在最前,然后是最近从这里进过的,
/// 不够数再按推荐补。都按存储值算,和效果目录解耦。
public enum NowPlayingCarouselEffectShelf {
    public static let recentStorageKey = "primuse.player.carousel.recentEffects"
    public static let recentLimit = 4
    public static let shelfLimit = 6

    public static func decodeRecent(_ storage: String) -> [String] {
        storage.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func encodeRecent(_ recent: [String]) -> String {
        recent.joined(separator: ",")
    }

    /// 记一笔「刚从这里进过」:挪到最前,去重,只留最近几种。
    public static func recording(_ effectID: String, into recent: [String], limit: Int = recentLimit) -> [String] {
        guard !effectID.isEmpty else { return Array(recent.prefix(limit)) }
        return Array(([effectID] + recent.filter { $0 != effectID }).prefix(max(limit, 0)))
    }

    /// 一排卡片的顺序。`available` 是目录里现有的效果(旧版本记下、新版本已经没有的丢掉)。
    public static func shelf(
        current: String,
        recent: [String],
        suggestions: [String],
        available: [String],
        limit: Int = shelfLimit
    ) -> [String] {
        let known = Set(available)
        var result: [String] = []
        for id in [current] + recent + suggestions where known.contains(id) && !result.contains(id) {
            result.append(id)
            if result.count == limit { break }
        }
        return result
    }
}

/// 调音那一面速度、音调两个步进键:在一列档位里往上或往下走一档。
public enum NowPlayingCarouselStepper {
    /// 和播放页「更多」里的播放速度同一列档位。
    public static let playbackRates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]

    /// 从 `value` 往上(`delta` 为正)或往下走 `|delta|` 档;`value` 不在档上时先走到相邻的那一档。
    /// 走到头就停在头上。
    public static func step(_ value: Double, by delta: Int, in choices: [Double]) -> Double {
        let sorted = choices.sorted()
        guard let first = sorted.first, let last = sorted.last, delta != 0 else { return value }
        let tolerance = 1e-6
        var current = value
        for _ in 0..<abs(delta) {
            if delta > 0 {
                current = sorted.first { $0 > current + tolerance } ?? last
            } else {
                current = sorted.last { $0 < current - tolerance } ?? first
            }
        }
        return current
    }

    /// 已经在最低 / 最高一档上了。
    public static func canStep(_ value: Double, by delta: Int, in choices: [Double]) -> Bool {
        abs(step(value, by: delta, in: choices) - value) > 1e-6
    }
}

/// 第一次打开转轮后在播放器上轻轻左右回弹一下,让人知道两边有东西。只做一次。
public enum NowPlayingCarouselHintPolicy {
    public static let shownStorageKey = "primuse.player.carousel.swipeHintShown"

    /// 回弹的几步,单位是页宽的比例,符号同手指的横向位移(负数露出右边那面)。最后一步回到 0。
    /// 两边都没有面时不回弹。
    public static func bounceSteps(hasLeading: Bool, hasTrailing: Bool) -> [Double] {
        switch (hasLeading, hasTrailing) {
        case (true, true): [-0.1, 0.08, 0]
        case (false, true): [-0.1, 0]
        case (true, false): [0.1, 0]
        case (false, false): []
        }
    }
}
