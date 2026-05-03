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
        syllables: [LyricSyllable]? = nil,
        voice: LyricVoice = .primary,
        background: [LyricLine]? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
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
        case id, timestamp, text, syllables, voice, background
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        self.timestamp = try c.decode(TimeInterval.self, forKey: .timestamp)
        self.text = try c.decode(String.self, forKey: .text)
        self.syllables = try c.decodeIfPresent([LyricSyllable].self, forKey: .syllables)
        self.voice = try c.decodeIfPresent(LyricVoice.self, forKey: .voice) ?? .primary
        self.background = try c.decodeIfPresent([LyricLine].self, forKey: .background)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(text, forKey: .text)
        try c.encodeIfPresent(syllables, forKey: .syllables)
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
