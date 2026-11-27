import Foundation

/// 按「专辑名 + 歌手」在线搜到的专辑封面候选可不可信。在线目录按相关度排序,
/// 第一条常常是完全无关的热门专辑(搜不到时尤其如此),所以候选必须先过这道
/// 身份检查才能当作这张专辑的封面;一条都过不了就宁可没有封面。
public enum AlbumArtworkMatchPolicy {
    public enum MatchStrength: Int, Sendable, Comparable {
        /// 专辑名一侧是另一侧加上版本后缀(「Thriller」对「Thriller 25」)。
        case prefix = 1
        /// 去掉版本标注后专辑名完全相同。
        case exact = 2

        public static func < (lhs: MatchStrength, rhs: MatchStrength) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    /// 拿去搜索的名字:空白、以及「未知专辑」「Unknown Artist」这类占位值都当作没有。
    /// `placeholders` 补上界面里本地化的占位文案(各语言的「未知艺术家」)。
    public static func searchableName(
        _ value: String?,
        placeholders: Set<String> = []
    ) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !TagCleanupPolicy.isPlaceholder(trimmed) else { return nil }
        let key = TagCleanupPolicy.normalizedKey(trimmed)
        if placeholders.contains(where: { TagCleanupPolicy.normalizedKey($0) == key }) {
            return nil
        }
        return trimmed
    }

    /// 候选与要找的专辑对得上多少;对不上返回 nil。
    /// - 不知道歌手时不认:只凭「Album 01」「Greatest Hits」这类专辑名,目录里同名的
    ///   专辑多得是(扫描刚开始、标签还没读出来时专辑名常常就是目录名);
    /// - 专辑名去掉括号里的版本标注与「 - Single」「 - Deluxe Edition」这类后缀后比较;
    /// - 两边都有歌手时歌手必须对上(允许「A」对「A & B」这种包含关系);
    /// - 只靠前缀对上的专辑名更容易撞车,要求两边都有歌手且完全相同。
    public static func matchStrength(
        requestedAlbum: String,
        requestedArtist: String?,
        candidateAlbum: String?,
        candidateArtist: String?
    ) -> MatchStrength? {
        let requested = albumKey(requestedAlbum)
        let candidate = albumKey(candidateAlbum ?? "")
        let requestedArtistKey = artistKey(requestedArtist)
        guard !requested.isEmpty, !candidate.isEmpty, !requestedArtistKey.isEmpty else { return nil }
        let strength: MatchStrength
        if requested == candidate {
            strength = .exact
        } else {
            let (shorter, longer) = requested.count <= candidate.count
                ? (requested, candidate)
                : (candidate, requested)
            guard shorter.count >= minimumPrefixKeyLength, longer.hasPrefix(shorter) else { return nil }
            strength = .prefix
        }

        let candidateArtistKey = artistKey(candidateArtist)
        guard !candidateArtistKey.isEmpty else {
            return strength == .exact ? strength : nil
        }
        if requestedArtistKey == candidateArtistKey { return strength }
        guard strength == .exact,
              requestedArtistKey.contains(candidateArtistKey)
                || candidateArtistKey.contains(requestedArtistKey) else { return nil }
        return strength
    }

    /// 在候选里挑最可信的一条:完全对上的优先,同等可信时按目录给的顺序。
    public static func bestMatchIndex(
        requestedAlbum: String,
        requestedArtist: String?,
        candidates: [(album: String?, artist: String?)]
    ) -> Int? {
        var best: (index: Int, strength: MatchStrength)?
        for (index, candidate) in candidates.enumerated() {
            guard let strength = matchStrength(
                requestedAlbum: requestedAlbum,
                requestedArtist: requestedArtist,
                candidateAlbum: candidate.album,
                candidateArtist: candidate.artist
            ) else { continue }
            if strength == .exact { return index }
            if best == nil { best = (index, strength) }
        }
        return best?.index
    }

    private static let minimumPrefixKeyLength = 4

    /// 「 - 」后面是这些词之一时,整段当作版本后缀去掉。
    private static let editionSuffixWords: Set<String> = [
        "single", "ep", "deluxe", "remastered", "remaster", "edition", "version",
        "anniversary", "expanded", "bonus", "live",
    ]

    static func albumKey(_ value: String) -> String {
        var text = strippingBracketedSegments(value)
        if let range = text.range(of: " - ", options: .backwards) {
            let tailWords = text[range.upperBound...]
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
            if !tailWords.isEmpty, tailWords.contains(where: editionSuffixWords.contains) {
                text = String(text[..<range.lowerBound])
            }
        }
        return comparableKey(text)
    }

    static func artistKey(_ value: String?) -> String {
        comparableKey(value ?? "")
    }

    private static func strippingBracketedSegments(_ value: String) -> String {
        var result = value
        for pattern in ["\\([^)]*\\)", "\\[[^\\]]*\\]", "（[^）]*）", "【[^】]*】"] {
            result = result.replacingOccurrences(of: pattern, with: " ", options: .regularExpression)
        }
        return result
    }

    private static func comparableKey(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }
}
