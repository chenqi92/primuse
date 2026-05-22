import Foundation

/// 中文 → 拼音转换 (无声调), 给 FTS5 搜索建索引和把用户 query 转拼音用。
///
/// 走 CoreFoundation `kCFStringTransformMandarinLatin` + `StripCombiningMarks`,
/// 系统级 API 无需第三方词表。同时保留原文里的 ASCII / 数字 — "Beyond 海阔
/// 天空" 会转成 "Beyond hai kuo tian kong", 让英文与中文混合的歌名也能命中。
public enum PinyinTransformer {
    /// 全句转拼音, 空格分隔每个汉字音节。non-CJK 字符原样保留。
    /// 返回 lowercased 结果。空字符串 / 全非 CJK 输入返回 nil (没有索引价值)。
    public static func pinyin(_ input: String) -> String? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cf = NSMutableString(string: trimmed)
        guard CFStringTransform(cf, nil, kCFStringTransformMandarinLatin, false) else {
            return nil
        }
        CFStringTransform(cf, nil, kCFStringTransformStripCombiningMarks, false)
        let result = (cf as String).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        // 如果转换后跟原文 lowercased 一致, 说明全是 ASCII 没拼音价值, 返回 nil
        // 避免在 FTS5 里塞重复 token。
        if result == trimmed.lowercased() { return nil }
        return result.isEmpty ? nil : result
    }

    /// 拼音首字母缩写, 给"zjl"匹配"周杰伦"这种用法。
    /// "周杰伦" → "zjl"; "Beyond 海阔天空" → "beyond hkts"。
    public static func initials(_ input: String) -> String? {
        guard let full = pinyin(input) else { return nil }
        let parts = full.split(separator: " ")
        let acronym = parts.compactMap { $0.first.map(String.init) }.joined()
        return acronym.isEmpty ? nil : acronym
    }
}
