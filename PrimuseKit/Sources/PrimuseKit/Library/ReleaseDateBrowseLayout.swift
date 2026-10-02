import Foundation

/// 资料库「发行日期」页:专辑按年代 → 年份分组,同一年里按艺术家排。
///
/// 整库专辑都要过一遍拼音转写与排序,只在后台建,视图拿建好的结果渲染。
public struct ReleaseDateBrowseLayout: Sendable {
    /// 年代分组。
    public enum Era: Hashable, Sendable {
        /// 某个年代,值是年代的起始年(1990 表示 1990–1999)。
        case decade(Int)
        /// `ReleaseDateBrowseLayoutBuilder.earliestDecade` 之前的年份。
        case earlier
        /// 没有年份、或年份明显写错(两位数、写成了日期串)。
        case unknown

        public var id: String {
            switch self {
            case .decade(let start): "decade-\(start)"
            case .earlier: "earlier"
            case .unknown: "unknown"
            }
        }

        /// `id` 反过来:专辑墙按年份分段时分段名就是它。
        public init?(id: String) {
            switch id {
            case "earlier": self = .earlier
            case "unknown": self = .unknown
            default:
                guard id.hasPrefix("decade-"), let start = Int(id.dropFirst("decade-".count)) else { return nil }
                self = .decade(start)
            }
        }
    }

    public struct Year: Identifiable, Sendable {
        /// nil 表示「未知年份」那一组。
        public let year: Int?
        public let albums: [Album]

        public var id: String { year.map { "year-\($0)" } ?? "year-unknown" }
    }

    public struct Decade: Identifiable, Sendable {
        public let era: Era
        /// 新的年份在前;未知年代只有一组 `year == nil`。
        public let years: [Year]
        public let albumCount: Int

        public var id: String { era.id }
    }

    /// 年代分布图上的一根柱子。
    public struct ChartBar: Identifiable, Equatable, Sendable {
        public let era: Era
        public let albumCount: Int

        public var id: String { era.id }
    }

    /// 新的年代在前,然后「更早」,最后「未知」。只列有专辑的。
    public let decades: [Decade]
    /// 分布图从左到右按时间先后:「更早」、各年代(中间没有专辑的年代也占一格,
    /// 高度为零,这样柱子的间隔就是真实的时间跨度)、最后是「未知」。
    public let chartBars: [ChartBar]
    public let albumCount: Int

    public init(decades: [Decade], chartBars: [ChartBar], albumCount: Int) {
        self.decades = decades
        self.chartBars = chartBars
        self.albumCount = albumCount
    }

    public static let empty = ReleaseDateBrowseLayout(decades: [], chartBars: [], albumCount: 0)
}

public enum ReleaseDateBrowseLayoutBuilder {
    /// 单独成一个年代的最早年代;再往前的都并进「更早」。
    public static let earliestDecade = 1960
    /// 早于这一年的不当年份看(多半是只写了两位数或标签写坏了)。
    public static let earliestPlausibleYear = 1000

    /// 能当发行年份用的年份。晚于明年的(写成日期串的 20150101 之类)不算。
    public static func plausibleYear(_ year: Int?, currentYear: Int) -> Int? {
        guard let year, year >= earliestPlausibleYear, year <= currentYear + 1 else { return nil }
        return year
    }

    public static func era(for year: Int?, currentYear: Int) -> ReleaseDateBrowseLayout.Era {
        guard let year = plausibleYear(year, currentYear: currentYear) else { return .unknown }
        guard year >= earliestDecade else { return .earlier }
        return .decade(year / 10 * 10)
    }

    /// - Parameters:
    ///   - albums: 资料库里可见的专辑,顺序不限。
    ///   - currentYear: 今年;超出明年的年份当作写错。
    ///   - unknownArtistName: 曲库给没有艺术家的专辑填的占位名,同一年里排在最后。
    public static func layout(
        albums: [Album],
        currentYear: Int,
        unknownArtistName: String? = nil
    ) -> ReleaseDateBrowseLayout {
        guard !albums.isEmpty else { return .empty }
        // 先按艺术家排好(同一艺术家的专辑已经按年份先后),再按年份稳定分桶:
        // 每一年里的专辑自然就是按艺术家排的。
        let artistOrdered = LibraryAlbumBrowseLayoutBuilder.layout(
            albums: albums,
            order: .artist,
            unknownArtistName: unknownArtistName
        ).items

        var albumsByYear: [Int: [Album]] = [:]
        var unknown: [Album] = []
        for album in artistOrdered {
            if let year = plausibleYear(album.year, currentYear: currentYear) {
                albumsByYear[year, default: []].append(album)
            } else {
                unknown.append(album)
            }
        }

        var yearsByEra: [ReleaseDateBrowseLayout.Era: [ReleaseDateBrowseLayout.Year]] = [:]
        for year in albumsByYear.keys.sorted(by: >) {
            let era = era(for: year, currentYear: currentYear)
            yearsByEra[era, default: []].append(
                ReleaseDateBrowseLayout.Year(year: year, albums: albumsByYear[year] ?? [])
            )
        }

        let decadeStarts = yearsByEra.keys.compactMap { era -> Int? in
            if case .decade(let start) = era { return start }
            return nil
        }
        var decades: [ReleaseDateBrowseLayout.Decade] = []
        for start in decadeStarts.sorted(by: >) {
            let years = yearsByEra[.decade(start)] ?? []
            decades.append(.init(era: .decade(start), years: years, albumCount: years.reduce(0) { $0 + $1.albums.count }))
        }
        if let earlier = yearsByEra[.earlier] {
            decades.append(.init(era: .earlier, years: earlier, albumCount: earlier.reduce(0) { $0 + $1.albums.count }))
        }
        if !unknown.isEmpty {
            decades.append(.init(era: .unknown, years: [.init(year: nil, albums: unknown)], albumCount: unknown.count))
        }

        var chartBars: [ReleaseDateBrowseLayout.ChartBar] = []
        if let earlier = yearsByEra[.earlier] {
            chartBars.append(.init(era: .earlier, albumCount: earlier.reduce(0) { $0 + $1.albums.count }))
        }
        if let first = decadeStarts.min(), let last = decadeStarts.max() {
            let counts = Dictionary(uniqueKeysWithValues: decades.compactMap { decade -> (Int, Int)? in
                if case .decade(let start) = decade.era { return (start, decade.albumCount) }
                return nil
            })
            for start in stride(from: first, through: last, by: 10) {
                chartBars.append(.init(era: .decade(start), albumCount: counts[start] ?? 0))
            }
        }
        if !unknown.isEmpty {
            chartBars.append(.init(era: .unknown, albumCount: unknown.count))
        }

        return ReleaseDateBrowseLayout(decades: decades, chartBars: chartBars, albumCount: artistOrdered.count)
    }
}
