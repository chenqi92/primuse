import Foundation

/// 「编辑快捷收藏」候选列表的筛选规则。
///
/// 这个页面要在整库(可能上万张专辑 / 艺术家)上挑出"还没固定 + 命中搜索词"的项。
/// 两条必须守住的性质:已固定项是按集合判断的(不能每个元素都去解码一次固定列表),
/// 以及**不重新排序** —— 专辑与艺术家来自资料库已经排好的集合, 歌单来自用户排定的
/// 顺序, 在这里再排一次既慢又会把用户的歌单顺序打乱。
public enum QuickAccessCandidatePolicy {
    /// 空搜索词命中一切;否则任一字段包含它即可(忽略大小写, 两端空白不算)。
    public static func matches(query: String, fields: [String?]) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return fields.contains { $0?.localizedCaseInsensitiveContains(trimmed) == true }
    }

    /// 保留原顺序, 去掉已固定的, 再按搜索词过滤。
    public static func filtered<Item>(
        _ items: [Item],
        id: (Item) -> String,
        pinnedIDs: Set<String>,
        query: String,
        searchFields: (Item) -> [String?]
    ) -> [Item] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            guard !pinnedIDs.contains(id(item)) else { return false }
            guard !trimmed.isEmpty else { return true }
            return matches(query: trimmed, fields: searchFields(item))
        }
    }
}
