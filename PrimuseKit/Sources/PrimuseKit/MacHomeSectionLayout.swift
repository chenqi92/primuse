import Foundation

/// Mac 首页主卡下面的区块。
///
/// 主卡(今晚听、接着听)固定在最上面,不参与排序。区块和 iPhone 首页不是一回事 ——
/// 资料库健康度、处理管线只有 Mac 有,所以单开一个枚举,不往 `HomeSectionKind` 里塞。
/// 顺序按 rawValue 存盘,和 `HomeSectionKind` 一样留在 Kit 里。
public enum MacHomeSection: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 资料库健康度 + 音乐源状态两张卡。
    case overview
    /// 音乐源 → 扫描 → 元数据 → 聆听。
    case pipeline
    case startListening
    /// 场景推荐。
    case forYou
    case recentlyAdded
    case recentlyPlayed
    case radio
    /// 在听的书 / 挑到首页的书。
    case books
    case podcasts
    case topArtists

    public var id: String { rawValue }
}

/// Mac 首页区块的先后,以及 Mac 独有那几块的显隐开关。
public enum MacHomeSectionLayout {
    public static let orderKey = "primuse.home.mac.sectionOrder.v1"
    public static let showsOverviewKey = "primuse.home.mac.showOverview"
    public static let showsPipelineKey = "primuse.home.mac.showPipeline"
    public static let showsBooksKey = "primuse.home.mac.showBooks"

    public static let defaultOrder: [MacHomeSection] = [
        .overview,
        .pipeline,
        .startListening,
        .forYou,
        .recentlyAdded,
        .recentlyPlayed,
        .radio,
        .books,
        .podcasts,
        .topArtists,
    ]

    /// 读回用户存的顺序。
    ///
    /// 按字符串逐个解,认不出的丢掉;存档里缺的块(新版本加的)跟在它默认顺序里的前一块后面,
    /// 前面一块都没有就放最前 —— 用户挪过顺序也不会被插到不相干的位置。
    public static func decodeOrder(_ rawValue: String) -> [MacHomeSection] {
        var seen = Set<MacHomeSection>()
        var result = decodeRawValues(rawValue)
            .compactMap(MacHomeSection.init(rawValue:))
            .filter { seen.insert($0).inserted }
        for (defaultIndex, missing) in defaultOrder.enumerated() where !seen.contains(missing) {
            let predecessor = defaultOrder[..<defaultIndex].last(where: seen.contains)
            let insertionIndex = predecessor
                .flatMap { result.firstIndex(of: $0) }
                .map { $0 + 1 } ?? 0
            result.insert(missing, at: insertionIndex)
            seen.insert(missing)
        }
        return result
    }

    /// 顺序等于默认时存空串,以后调整默认顺序,没动过的用户会跟着走。
    public static func encodeOrder(_ sections: [MacHomeSection]) -> String {
        let normalized = decodeOrder(encodeRawValues(sections.map(\.rawValue)))
        guard normalized != defaultOrder else { return "" }
        return encodeRawValues(normalized.map(\.rawValue))
    }

    /// 设置里拖动一行:把 `source` 那几行挪到 `destination` 之前(下标都是挪动前的)。
    public static func reordering(
        _ order: [MacHomeSection],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [MacHomeSection] {
        var result = decodeOrder(encodeRawValues(order.map(\.rawValue)))
        let validSource = IndexSet(source.filter { result.indices.contains($0) })
        guard !validSource.isEmpty else { return result }
        let clampedDestination = min(max(destination, 0), result.count)
        let picked = validSource.map { result[$0] }
        let insertionIndex = clampedDestination - validSource.filter { $0 < clampedDestination }.count
        for index in validSource.reversed() {
            result.remove(at: index)
        }
        result.insert(contentsOf: picked, at: insertionIndex)
        return result
    }

    private static func decodeRawValues(_ rawValue: String) -> [String] {
        guard let data = rawValue.data(using: .utf8),
              let values = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return values
    }

    private static func encodeRawValues(_ values: [String]) -> String {
        guard let data = try? JSONEncoder().encode(values) else { return "" }
        return String(decoding: data, as: UTF8.self)
    }
}
