import Foundation

/// 歌单页「在歌单里找歌」的匹配规则。
///
/// 搜索词按空白切成几个词，每个词都要在歌名、艺人、专辑里的某一处出现，词与词可以落在不同
/// 字段上（「周杰伦 晴天」）。比较时不分大小写、全半角和变音符号。
///
/// 只决定一行留不留，不排序：歌单顺序或用户选的显示排序原样保留。
public enum LibraryFindPolicy {
    public struct Query: Equatable, Sendable {
        public let words: [String]
    }

    private static let comparisonOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]

    /// 空白（或只有空格）时返回 nil，表示不筛选。
    public static func query(_ raw: String) -> Query? {
        let words = raw
            .folding(options: comparisonOptions, locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        return words.isEmpty ? nil : Query(words: words)
    }

    public static func matches(_ query: Query, fields: [String?]) -> Bool {
        query.words.allSatisfy { word in
            fields.contains { $0?.range(of: word, options: comparisonOptions) != nil }
        }
    }

    public static func matches(_ query: Query, song: Song) -> Bool {
        var fields: [String?] = [song.title, song.artistName, song.albumArtistName, song.albumTitle]
        if let sourceArtistNames = song.sourceArtistNames {
            fields.append(contentsOf: sourceArtistNames.map(Optional.some))
        }
        return matches(query, fields: fields)
    }

    /// 导入时没对上的置灰条目也算歌单里的一首，一并能找到。
    public static func matches(_ query: Query, pending entry: PlaylistPendingEntry) -> Bool {
        matches(query, fields: [entry.title, entry.album] + entry.artists.map(Optional.some))
    }
}
