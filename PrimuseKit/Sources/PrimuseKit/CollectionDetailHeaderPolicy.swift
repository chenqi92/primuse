import Foundation

/// 集合详情页(专辑、艺术家、歌单、智能歌单、风格)头图里那行元信息的拼法。
///
/// 头图的画法随界面皮肤换(`SkinSurface.collectionDetail`),写什么只在这里定一次:
/// 换一种画法不会让专辑页少写了格式、或者歌单页把总时长写成另一种样子。
public enum CollectionDetailHeaderPolicy {
    /// 元信息各段之间的分隔。
    public static let separator = " \u{00B7} "

    /// 专辑:流派 · 年份 · 格式。流派去掉首尾空白后为空就不写;格式只在整张专辑一致时才写
    /// (混了多种格式的专辑写哪个都不对)。
    public static func albumMeta(genre: String?, year: Int?, formats: Set<String>) -> String {
        var parts: [String] = []
        if let genre = genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            parts.append(genre)
        }
        if let year { parts.append(String(year)) }
        if formats.count == 1, let format = formats.first, !format.isEmpty {
            parts.append(format)
        }
        return parts.joined(separator: separator)
    }

    /// 歌单与智能歌单:「N 首 · 总时长」。总时长不是正数时只写数量(时长只在需要时才格式化)。
    public static func countAndDuration(
        countText: String,
        totalSeconds: Double,
        durationText: (Double) -> String
    ) -> String {
        guard totalSeconds > 0 else { return countText }
        return countText + separator + durationText(totalSeconds)
    }
}
