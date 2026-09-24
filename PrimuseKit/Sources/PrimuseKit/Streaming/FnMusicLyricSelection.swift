import CoreFoundation
import Foundation

/// 飞牛音乐 `/lyric/list` 的候选选择，照官方网页端的规则移植，手机、Mac 与
/// Apple TV 三端共用一份。
///
/// 网页端的做法：候选先按来源优先级（内嵌 > 外部 LRC > 手动 > 未知），再按
/// `updatedAt`、`createdAt` 倒序排好；`preferred` 命中且解析得出内容就用它，否则
/// 顺着排好的候选找第一份带同步行的歌词，都没有就退到第一份纯文本。以前只认
/// `preferred`，它指向的歌词被删掉或内容为空时会直接显示无歌词。
///
/// 服务端还会给每份歌词一个 `offset`（毫秒，正值＝歌词提前显示），是用户在飞牛
/// 里校准过的值。`Document.text` 把它并进 LRC 的 `[offset:]` 标签，后面整条歌词
/// 解析链路就自动生效，不用再传一个偏移字段。
public enum FnMusicLyricSelection {
    /// 服务端 `source` 字段是数字：1 内嵌、2 外部 LRC、4 手动，其余当未知。
    /// 原始值即优先级，数值大的优先。
    public enum Source: Int, Comparable, Sendable {
        case unknown = 1
        case manual = 2
        case externalLRC = 3
        case embedded = 4

        public static func < (lhs: Source, rhs: Source) -> Bool { lhs.rawValue < rhs.rawValue }

        init(serverValue: Any?) {
            switch FnMusicLyricSelection.number(serverValue).map(Int.init) {
            case 1: self = .embedded
            case 2: self = .externalLRC
            case 4: self = .manual
            default: self = .unknown
            }
        }
    }

    public struct Candidate: Sendable, Equatable {
        public let guid: String?
        public let content: String
        public let source: Source
        public let offsetMilliseconds: Int?
        public let updatedAt: Double
        public let createdAt: Double

        public init(
            guid: String?,
            content: String,
            source: Source = .unknown,
            offsetMilliseconds: Int? = nil,
            updatedAt: Double = 0,
            createdAt: Double = 0
        ) {
            self.guid = guid
            self.content = content
            self.source = source
            self.offsetMilliseconds = offsetMilliseconds
            self.updatedAt = updatedAt
            self.createdAt = createdAt
        }
    }

    public struct Document: Sendable, Equatable {
        public let guid: String?
        public let content: String
        public let offsetMilliseconds: Int?

        /// 交给歌词解析器的文本。服务端偏移非零时写成 `[offset:]` 标签；歌词自带
        /// 的标签会被合并而不是叠加：飞牛网页端解析时把自带标签**加**到时间戳上
        /// （正值＝推后），再把服务端偏移当作播放器偏移（正值＝提前），用户是对着
        /// 这个效果校准的；Primuse 的标签正值＝提前，所以要写成 `服务端 − 自带`
        /// 才能得到同样的时间线。服务端偏移缺席或为零时原文照给，不改动自带标签。
        public var text: String {
            guard let offsetMilliseconds, offsetMilliseconds != 0 else { return content }
            let lines = content
                .replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: "\n")
            var embedded = 0
            var kept: [String] = []
            kept.reserveCapacity(lines.count + 1)
            for line in lines {
                if let tagged = FnMusicLyricSelection.offsetTagMilliseconds(in: line) {
                    embedded = tagged
                    continue
                }
                kept.append(line)
            }
            return (["[offset:\(offsetMilliseconds - embedded)]"] + kept).joined(separator: "\n")
        }
    }

    /// `/lyric/list` 去掉 `{code,msg,data}` 外壳后的 `data`。接受 `{list, preferred}`，
    /// 也接受直接是数组的旧形状；`list` 为 null 视为空。
    public static func select(payload: Any?) -> Document? {
        let (candidates, preferred) = candidates(in: payload)
        return select(candidates: candidates, preferred: preferred)
    }

    public static func candidates(in payload: Any?) -> (list: [Candidate], preferred: String?) {
        let dictionary = payload as? [String: Any]
        let rawList = dictionary?["list"] as? [[String: Any]]
            ?? payload as? [[String: Any]]
            ?? []
        let preferred = nonemptyString(dictionary?["preferred"])
        let list = rawList.compactMap { item -> Candidate? in
            guard let content = nonemptyString(item["content"]) ?? nonemptyString(item["text"]) else {
                return nil
            }
            return Candidate(
                guid: nonemptyString(item["guid"]) ?? nonemptyString(item["id"]),
                content: content,
                source: Source(serverValue: item["source"]),
                offsetMilliseconds: number(item["offset"]).map { Int($0.rounded()) },
                updatedAt: number(item["updatedAt"]) ?? 0,
                createdAt: number(item["createdAt"]) ?? 0
            )
        }
        return (list, preferred)
    }

    public static func select(candidates: [Candidate], preferred: String?) -> Document? {
        guard !candidates.isEmpty else { return nil }
        let sorted = candidates.sorted { lhs, rhs in
            if lhs.source != rhs.source { return lhs.source > rhs.source }
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.createdAt > rhs.createdAt
        }
        if let preferred, !preferred.isEmpty,
           let chosen = sorted.first(where: { $0.guid == preferred }),
           isUsable(chosen) {
            return document(chosen)
        }
        var fallback: Candidate?
        for candidate in sorted {
            if !hasTimestamps(candidate.content) {
                // 纯文本歌词只在找不到任何同步歌词时兜底。
                if fallback == nil { fallback = candidate }
                continue
            }
            if syncedLineCount(candidate.content) > 0 { return document(candidate) }
            // 带时间戳却解析不出一行的歌词是坏文件，不做兜底。
        }
        return fallback.map(document)
    }

    // MARK: - 解析判定

    /// 网页端判定「像同步歌词」的正则，全角方括号也算。
    private static let timestampPattern = try! NSRegularExpression(
        pattern: #"[\[［]\d{1,3}:\d{2}(?:[.:]\d{1,3})?[\]］]"#
    )
    private static let leadingTimestampsPattern = try! NSRegularExpression(
        pattern: #"^(?:\s*[\[［]\d{1,3}:\d{2}(?:[.:]\d{1,3})?[\]］])+"#
    )
    private static let offsetTagPattern = try! NSRegularExpression(
        pattern: #"^\s*\[\s*[Oo][Ff][Ff][Ss][Ee][Tt]\s*:\s*([+-]?\d+)\s*\]\s*$"#
    )

    static func hasTimestamps(_ content: String) -> Bool {
        timestampPattern.firstMatch(in: content, range: NSRange(content.startIndex..., in: content)) != nil
    }

    /// 以时间戳开头且去掉时间戳后还有文字的行数。网页端会丢掉只有时间戳的空行，
    /// 这里同样不算数。
    static func syncedLineCount(_ content: String) -> Int {
        content.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline).reduce(into: 0) { count, rawLine in
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            guard let match = leadingTimestampsPattern.firstMatch(in: line, range: range),
                  let matched = Range(match.range, in: line) else { return }
            let remainder = line[matched.upperBound...]
                .replacingOccurrences(of: #"[\[［]\d{1,3}:\d{2}(?:[.:]\d{1,3})?[\]］]"#, with: "", options: .regularExpression)
            if !remainder.trimmingCharacters(in: .whitespaces).isEmpty { count += 1 }
        }
    }

    /// 网页端 `rl` 的判定：带时间戳却一行都解析不出来的候选作废，其余都能用。
    static func isUsable(_ candidate: Candidate) -> Bool {
        !hasTimestamps(candidate.content) || syncedLineCount(candidate.content) > 0
    }

    static func offsetTagMilliseconds(in line: String) -> Int? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = offsetTagPattern.firstMatch(in: line, range: range),
              let valueRange = Range(match.range(at: 1), in: line) else { return nil }
        return Int(line[valueRange])
    }

    private static func document(_ candidate: Candidate) -> Document {
        Document(guid: candidate.guid, content: candidate.content, offsetMilliseconds: candidate.offsetMilliseconds)
    }

    private static func nonemptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 只认有限数值；网页端对 `offset`、`source`、时间戳字段同样不接受字符串。
    /// 先按 CF 类型排除布尔：Darwin 上 `NSNumber(1) as? Bool` 也能成功，按 Swift 类型
    /// 判断会把 `source: 1`（内嵌）当成布尔丢掉。
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            return value.doubleValue.isFinite ? value.doubleValue : nil
        }
        if let value = value as? Int { return Double(value) }
        if let value = value as? Double { return value.isFinite ? value : nil }
        return nil
    }
}
