import Foundation

/// 播放页「转轮」里播放器两侧的一页。播放器本身永远在中间，不在这里面。
///
/// 只在 iPhone / iPad 的音乐播放页上出现；macOS 与 tvOS 不做转轮。
public enum NowPlayingCarouselPanel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// 均衡器(和设置里同一套频段与预设)。
    case equalizer
    /// 混响、压缩这些音效。
    case audioEffects
    /// 和正在放的这首相似的歌。
    case similarSongs
    /// 这首所在专辑的曲目,以及同一艺人的其他歌。
    case albumAndArtist
    /// 接下来播放。
    case queue
    /// 卡拉 OK 舞台。
    case karaoke

    public var id: String { rawValue }
}

/// 转轮的排布:播放器左边几页、右边几页。两边的数组都是**从播放器往外数**,第一个紧挨着播放器。
///
/// 一页只能出现一次;每边最多 `maximumPanelsPerSide` 页。存成一行文本 `左|右`
/// (如 `equalizer,audioEffects|karaoke`),读到不认识的页名直接丢掉,不让整份配置失效。
public struct NowPlayingCarouselConfiguration: Equatable, Sendable {
    public enum Side: String, CaseIterable, Sendable {
        case leading
        case trailing
    }

    /// 转轮总开关。默认关:打开之前播放页的左右滑动不做任何事。
    public static let enabledStorageKey = "primuse.player.carousel.enabled"
    public static let enabledByDefault = false
    /// 两边各放哪几页。
    public static let storageKey = "primuse.player.carousel.layout"
    public static let maximumPanelsPerSide = 4

    public static let `default` = NowPlayingCarouselConfiguration(
        leading: [.equalizer, .audioEffects, .similarSongs, .albumAndArtist],
        trailing: [.karaoke, .queue]
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
                NowPlayingCarouselPanel(rawValue: $0.trimmingCharacters(in: .whitespaces))
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

    /// 还没放进转轮的页,按枚举顺序。
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

    // MARK: 编辑

    /// 把一页放到某一边的 `index`(越界就放到最外面)。原来在哪儿都先拿走;那一边满了就不动。
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
}
