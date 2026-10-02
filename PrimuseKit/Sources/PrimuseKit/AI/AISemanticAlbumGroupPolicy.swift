import Foundation

/// AI 语义搜索补充结果里的一组。
public enum AISemanticResultGroup: String, CaseIterable, Sendable {
    case albums
    case songs
}

/// AI 补充结果里专辑组与歌曲组谁在前。
///
/// 默认歌曲在前(语义检索主要是找歌);搜索词像是在找一张专辑时专辑组在前:
/// 带着「专辑」「整张」「那张」这类词,或者和某张专辑的名字高度重合。
public enum AISemanticAlbumGroupPolicy {
    /// 说明在找「一张唱片」的词。中日韩直接按子串认。
    static let albumCueWords = [
        "专辑", "專輯", "整张", "整張", "那张", "那張", "这张", "這張", "哪张", "哪張", "唱片",
        "アルバム", "앨범",
    ]
    /// 拉丁文字的词按整词认,`deep` 里的 `ep` 不算。
    static let latinAlbumCueWords: Set<String> = ["album", "albums", "lp", "ep"]
    /// 搜索词里包含一个专辑名时,专辑名至少要这么长(字符)才算高度匹配 ——
    /// 再短的(「21」「红豆」)更可能只是碰巧出现在一句话里。
    static let containedTitleMinimumLength = 4

    public static func groupOrder(query: String, albumTitles: [String]) -> [AISemanticResultGroup] {
        queryLooksLikeAlbum(query, albumTitles: albumTitles) ? [.albums, .songs] : [.songs, .albums]
    }

    public static func queryLooksLikeAlbum(_ query: String, albumTitles: [String]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if hasAlbumCue(trimmed) { return true }
        let normalizedQuery = normalized(trimmed)
        guard !normalizedQuery.isEmpty else { return false }
        return albumTitles.contains { title in
            closelyMatches(query: normalizedQuery, title: normalized(title))
        }
    }

    static func hasAlbumCue(_ query: String) -> Bool {
        if albumCueWords.contains(where: { query.contains($0) }) { return true }
        let words = query
            .folding(options: [.caseInsensitive, .widthInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        return words.contains { latinAlbumCueWords.contains($0) }
    }

    /// 两边都折叠过大小写、全半角、变音符,去掉空白与标点。
    static func closelyMatches(query: String, title: String) -> Bool {
        guard !title.isEmpty else { return false }
        if query == title { return true }
        // 「播放 Abbey Road 整张」这类:专辑名整个出现在搜索词里,且占了一半以上或者足够长。
        if query.contains(title),
           title.count >= containedTitleMinimumLength || title.count * 2 >= query.count {
            return true
        }
        // 只打了专辑名的大半(「abbey roa」)。
        if query.count >= 2, title.contains(query), query.count * 10 >= title.count * 6 {
            return true
        }
        return false
    }

    static func normalized(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: nil
        )
        return String(folded.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }.map(Character.init))
    }
}
