import Foundation

public struct LyricSyllable: Codable, Hashable, Sendable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(text: String, start: TimeInterval, end: TimeInterval) {
        self.text = text
        self.start = start
        self.end = end
    }
}

/// 行所属声部。LRC/A2 没有该信息，预留给 TTML（Apple Music 对唱）等格式。
public enum LyricVoice: String, Codable, Sendable, CaseIterable {
    case primary    // 主声部 / 默认演唱者，左对齐
    case secondary  // 对唱声部，建议右对齐
}

public struct LyricLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var timestamp: TimeInterval
    public var text: String
    /// Whether tapping and playback time may drive this line. Plain-text
    /// lyrics intentionally keep every line unsynchronized even though their
    /// compatibility timestamp is zero.
    public var isSynchronized: Bool
    /// 字级数据；nil 表示行级歌词。
    public var syllables: [LyricSyllable]?
    /// 声部归属，默认主声部。
    public var voice: LyricVoice
    /// 背景和声子行（同一时间窗内附唱）。`background` 内的 background 应永远为 nil。
    public var background: [LyricLine]?

    public init(
        id: String = UUID().uuidString,
        timestamp: TimeInterval,
        text: String,
        isSynchronized: Bool? = nil,
        syllables: [LyricSyllable]? = nil,
        voice: LyricVoice = .primary,
        background: [LyricLine]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.isSynchronized = isSynchronized ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.syllables = syllables
        self.voice = voice
        self.background = background
    }

    /// 行结束时间。字级行用最后一字的 end；行级行无信息，外部需要靠下一行 timestamp 推。
    public var endTime: TimeInterval? { syllables?.last?.end }

    public var isWordLevel: Bool { syllables?.isEmpty == false }
}

// MARK: - Codable (custom — 旧 JSON 缺 voice/background 也能解码)

extension LyricLine: Codable {
    private enum CodingKeys: String, CodingKey {
        case id, timestamp, text, isSynchronized, syllables, voice, background
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        self.text = try c.decode(String.self, forKey: .text)
        self.syllables = try c.decodeIfPresent([LyricSyllable].self, forKey: .syllables)
        self.isSynchronized = try c.decodeIfPresent(Bool.self, forKey: .isSynchronized)
            ?? (timestamp > 0 || syllables?.isEmpty == false)
        self.voice = try c.decodeIfPresent(LyricVoice.self, forKey: .voice) ?? .primary
        self.background = try c.decodeIfPresent([LyricLine].self, forKey: .background)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(syllables, forKey: .syllables)
        let inferredSynchronization = timestamp > 0 || syllables?.isEmpty == false
        if isSynchronized != inferredSynchronization {
            try c.encode(isSynchronized, forKey: .isSynchronized)
        }
        // voice / background 仅在非默认值时写入，避免老歌词缓存膨胀
        if voice != .primary { try c.encode(voice, forKey: .voice) }
        try c.encodeIfPresent(background, forKey: .background)
    }
}

public enum LyricsFormat: String, Codable, Sendable, CaseIterable {
    case plain      // 无时间戳的纯文本
    case lineLevel  // 行级 LRC：[mm:ss.xx]text
    case wordLevel  // 字级：A2 扩展 LRC（<mm:ss.xx>word）或 KRC 偏移格式（<offset,duration,0>word）

    /// 通过扫描内容探测歌词格式。仅看是否存在字级 / 行级时间标记。
    public static func detect(_ content: String?) -> LyricsFormat {
        guard let content, !content.isEmpty else { return .plain }
        if content.range(of: #"<\d+:\d+(\.\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.range(of: #"<\d+,\d+(,\d+)?>"#, options: .regularExpression) != nil {
            return .wordLevel
        }
        if content.range(of: #"\[\d+:\d+(\.\d+)?\]"#, options: .regularExpression) != nil {
            return .lineLevel
        }
        return .plain
    }

    public var isSynced: Bool { self != .plain }
}

public enum LyricsContentParser {
    nonisolated(unsafe) private static let lineHeadPattern = /\[(\d+):(\d{2})(?:[.:](\d{1,3}))?\]/
    nonisolated(unsafe) private static let relativeLineHeadPattern = /^\[(\d+),(\d+)\]/
    nonisolated(unsafe) private static let inlineWordPattern = /<(\d+):(\d{2})(?:[.:](\d{1,3}))?>/
    nonisolated(unsafe) private static let relativeWordPattern = /<(\d+),(\d+)(?:,\d+)?>/

    public static func parse(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for raw in content.components(separatedBy: .newlines) {
            let heads = raw.matches(of: lineHeadPattern)
            if heads.isEmpty {
                guard let head = raw.firstMatch(of: relativeLineHeadPattern) else { continue }
                let lineStart = (Double(head.1) ?? 0) / 1000
                let body = String(raw[head.range.upperBound...])
                if let parsed = parseWordLevelLine(body: body, lineStart: lineStart) {
                    lines.append(parsed)
                } else {
                    let text = body.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    lines.append(LyricLine(timestamp: lineStart, text: text, isSynchronized: true))
                }
                continue
            }

            guard let lastHead = heads.last else { continue }
            let body = String(raw[lastHead.range.upperBound...])
            for head in heads {
                guard let lineStart = parseTimestamp(min: head.1, sec: head.2, frac: head.3) else {
                    continue
                }
                if let parsed = parseWordLevelLine(body: body, lineStart: lineStart) {
                    lines.append(parsed)
                } else {
                    let text = body.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    lines.append(LyricLine(timestamp: lineStart, text: text, isSynchronized: true))
                }
            }
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    public static func parseText(_ text: String) -> [LyricLine] {
        let synchronized = parse(text)
        if !synchronized.isEmpty { return synchronized }

        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(timestamp: 0, text: $0.element, isSynchronized: false) }
    }

    private static func parseWordLevelLine(
        body: String,
        lineStart: TimeInterval
    ) -> LyricLine? {
        let marks = body.matches(of: inlineWordPattern)
        guard !marks.isEmpty else {
            return parseRelativeWordLevelLine(body: body, lineStart: lineStart)
        }

        var syllables: [LyricSyllable] = []
        for (index, mark) in marks.enumerated() {
            guard let start = parseTimestamp(min: mark.1, sec: mark.2, frac: mark.3) else {
                continue
            }
            let textStart = mark.range.upperBound
            let textEnd = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])
            if chunk.isEmpty {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, start)
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(text: chunk, start: start, end: start))
        }

        guard !syllables.isEmpty else { return nil }
        for index in 0..<(syllables.count - 1) {
            syllables[index].end = max(syllables[index].end, syllables[index + 1].start)
        }
        if let lastIndex = syllables.indices.last,
           syllables[lastIndex].end <= syllables[lastIndex].start {
            syllables[lastIndex].end = syllables[lastIndex].start + 0.4
        }

        return makeWordLevelLine(lineStart: lineStart, syllables: syllables)
    }

    private static func parseRelativeWordLevelLine(
        body: String,
        lineStart: TimeInterval
    ) -> LyricLine? {
        let marks = body.matches(of: relativeWordPattern)
        guard !marks.isEmpty else { return nil }

        var syllables: [LyricSyllable] = []
        for (index, mark) in marks.enumerated() {
            let offset = (Double(mark.1) ?? 0) / 1000
            let duration = (Double(mark.2) ?? 0) / 1000
            let start = lineStart + offset
            let end = duration > 0 ? start + duration : start
            let textStart = mark.range.upperBound
            let textEnd = index + 1 < marks.count ? marks[index + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])
            if chunk.isEmpty {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text,
                        start: last.start,
                        end: max(last.end, end)
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(text: chunk, start: start, end: end))
        }

        guard !syllables.isEmpty else { return nil }
        for index in 0..<(syllables.count - 1) where syllables[index].end <= syllables[index].start {
            syllables[index].end = syllables[index + 1].start
        }
        if let lastIndex = syllables.indices.last,
           syllables[lastIndex].end <= syllables[lastIndex].start {
            syllables[lastIndex].end = syllables[lastIndex].start + 0.4
        }

        return makeWordLevelLine(lineStart: lineStart, syllables: syllables)
    }

    private static func makeWordLevelLine(
        lineStart: TimeInterval,
        syllables: [LyricSyllable]
    ) -> LyricLine? {
        let text = syllables.map(\.text).joined()
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return LyricLine(
            timestamp: lineStart,
            text: text,
            isSynchronized: true,
            syllables: syllables
        )
    }

    private static func parseTimestamp(
        min: Substring,
        sec: Substring,
        frac: Substring?
    ) -> TimeInterval? {
        guard let minutes = Double(min), minutes.isFinite, minutes >= 0,
              let seconds = Double(sec), seconds.isFinite, (0..<60).contains(seconds),
              let fraction = Double(frac ?? "0"), fraction.isFinite else {
            return nil
        }
        let divisor = pow(10, Double(frac?.count ?? 2))
        let result = minutes * 60 + seconds + fraction / divisor
        guard result.isFinite, result <= 7 * 24 * 3600 else { return nil }
        return result
    }
}
