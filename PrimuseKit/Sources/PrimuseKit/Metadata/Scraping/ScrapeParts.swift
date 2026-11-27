import Foundation

/// 一次刮削要写进资料库的部分。整张专辑补全、多选刮削可以只补歌词或只补封面。
public struct ScrapeParts: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// 标签:标题、艺术家、专辑、轨号、碟号、年份、流派,以及时长、码率这些技术信息。
    public static let metadata = ScrapeParts(rawValue: 1 << 0)
    public static let cover = ScrapeParts(rawValue: 1 << 1)
    public static let lyrics = ScrapeParts(rawValue: 1 << 2)
    public static let all: ScrapeParts = [.metadata, .cover, .lyrics]
}
