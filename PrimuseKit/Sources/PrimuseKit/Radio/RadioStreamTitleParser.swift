import Foundation

/// 一条 `StreamTitle` 解析后的结构。电台推什么全凭台方心情 —— 可能是
/// 「艺术家 - 曲名」，也可能是节目名、台宣、甚至一句广告。所以这里既保留
/// 原文(界面一定有东西可显示)，也给出尽力拆出的艺术家/曲名，
/// 外加一个「这看起来像不像一首歌」的判断，供歌词/封面查找决定要不要出手。
public struct RadioStreamTitle: Equatable, Sendable {
    /// 清洗过的原文。界面直接显示这个。
    public let rawText: String
    public let artist: String?
    public let title: String?

    public init(rawText: String, artist: String?, title: String?) {
        self.rawText = rawText
        self.artist = artist
        self.title = title
    }

    /// 拆出了艺术家和曲名，才值得拿去查歌词或专辑封面。
    public var looksLikeTrack: Bool { artist != nil && title != nil }
}

public enum RadioStreamTitleParser {
    /// 「艺术家 - 曲名」里出现过的各种破折号与竖线。顺序有意义：
    /// 先试两侧带空格的形态，避免把 `Jay-Z` 这种名字里的连字符当成分隔符。
    private static let separators = [" - ", " – ", " — ", " -- ", " | ", " / ", "-", "–"]

    /// 判断「开头那一段是不是域名」时只认两侧带空格的分隔符。
    /// 用裸连字符会把 `radio-nova.fr - Ecoutez` 的开头切成 `radio`，
    /// 域名就再也认不出来了。
    private static let spacedSeparators = [" - ", " – ", " — ", " -- ", " | ", " / "]

    /// 明显不是曲目的文本特征。命中就不再往下拆 —— 拿一句广告去查歌词
    /// 只会得到一个错的封面。
    private static let advertisementMarkers = [
        "advert", "advertisement", "jingle", "sponsor", "sweeper", "station id",
        "stationid", "www.", "http://", "https://", ".com/", ".net/", "listen live",
        "now on air", "coming up",
    ]

    /// 台宣常写成 `品牌域名 - 一句广告词`。把域名当艺术家拿去查歌词，
    /// 查回来的一定是错的，所以整条按非曲目处理。
    ///
    /// 只认白名单里的顶级域，免得把 `Mr.Kitty`、`R.E.M.` 这类乐队名误伤。
    private static let advertisementTopLevelDomains: Set<String> = [
        "com", "net", "org", "info", "biz", "live", "radio", "online", "fm", "tv",
        "io", "app", "shop", "store", "de", "fr", "es", "it", "nl", "pl", "ru",
        "uk", "us", "ca", "au", "cn", "jp", "kr", "br", "mx", "se", "no", "dk",
        "fi", "cz", "hu", "ro", "gr", "pt", "tr", "ua", "in", "id", "ch", "at",
    ]

    public static func parse(_ raw: String?) -> RadioStreamTitle? {
        guard let raw else { return nil }
        let text = normalizedWhitespace(raw)
        guard !text.isEmpty else { return nil }

        guard !looksLikeAdvertisement(text) else {
            return RadioStreamTitle(rawText: text, artist: nil, title: nil)
        }

        guard let split = split(text) else {
            return RadioStreamTitle(rawText: text, artist: nil, title: nil)
        }
        return RadioStreamTitle(rawText: text, artist: split.0, title: split.1)
    }

    /// 两条 `StreamTitle` 是否表示同一首。电台会每隔几秒重复推送同一条，
    /// 界面不该因此重置动画，歌词也不该反复重查。
    public static func isSameTrack(_ lhs: RadioStreamTitle?, _ rhs: RadioStreamTitle?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return comparisonKey(lhs) == comparisonKey(rhs)
    }

    private static func comparisonKey(_ value: RadioStreamTitle) -> String {
        value.rawText
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedWhitespace(_ raw: String) -> String {
        raw.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func looksLikeAdvertisement(_ text: String) -> Bool {
        let lowered = text.lowercased()
        if advertisementMarkers.contains(where: { lowered.contains($0) }) { return true }
        // 只看第一段：域名出现在开头才是台宣，出现在曲名里(`Song (feat. x.com)`)不算。
        return looksLikeDomain(leadingField(lowered))
    }

    /// 取最早出现的分隔符之前的那一段。
    private static func leadingField(_ text: String) -> String {
        var head = text
        for separator in spacedSeparators {
            guard let range = text.range(of: separator) else { continue }
            let candidate = String(text[text.startIndex..<range.lowerBound])
            if candidate.count < head.count { head = candidate }
        }
        return head.trimmingCharacters(in: .whitespaces)
    }

    private static func looksLikeDomain(_ value: String) -> Bool {
        guard !value.isEmpty,
              !value.contains(" "),
              value.contains(".") else {
            return false
        }
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2,
              let last = parts.last,
              parts.dropLast().allSatisfy({ !$0.isEmpty }) else {
            return false
        }
        return advertisementTopLevelDomains.contains(String(last))
    }

    private static func split(_ text: String) -> (String, String)? {
        for separator in separators {
            guard let range = text.range(of: separator) else { continue }
            let lhs = String(text[text.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let rhs = String(text[range.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            guard isPlausibleField(lhs), isPlausibleField(rhs) else { continue }
            return (lhs, rhs)
        }
        return nil
    }

    /// 拆出来的两半都得像个名字：非空、不是纯标点、也不能长到像一段描述。
    private static func isPlausibleField(_ value: String) -> Bool {
        guard value.count >= 2, value.count <= 120 else { return false }
        return value.rangeOfCharacter(from: .alphanumerics) != nil
    }
}
