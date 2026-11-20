import Foundation

/// 有声内容的一份文字稿是从哪来的(#461),决定别的来路能不能自动换掉它。
public enum SpokenTranscriptOrigin: Equatable, Sendable {
    /// 用户在 Primuse 里编辑过,或从文件导入的。只存在本机(`documentIsLocalOverride`)。
    case userProvided
    /// 音乐源服务器上的外部文字稿(Audiobookshelf 音频旁边同名的 .vtt、.lrc、.srt……)。
    case server
    /// 本机识别、内置智能、自己的密钥或阿里云生成的。
    case generated
    /// 其余:节目自带的、音频旁边的文件、标签里的……
    case other

    public init?(lines: [LyricLine]) {
        guard let first = lines.first else { return nil }
        if first.documentIsLocalOverride {
            self = .userProvided
            return
        }
        switch LyricsDocumentSource.of(lines)?.kind {
        case .server: self = .server
        case .transcript: self = .generated
        default: self = .other
        }
    }
}

/// 三种来路之间谁能换掉谁:
/// - 用户编辑、导入的最优先:服务器稿、生成稿都不会自动换掉它。只有用户点「重新读取服务器文字稿」
///   并确认替换时才换,换下来的那份留在歌词来源里,随时能换回去。
/// - 服务器上的外部文字稿优先于生成稿:后台核对读到服务器稿就换掉生成稿,哪怕生成稿是逐字的、
///   服务器稿只是逐句的。
/// - 手上是服务器稿时用户又明确生成了一份:生成的这份固定下来,后台核对不再把服务器稿换回来;
///   想换回去用「重新读取服务器文字稿」或歌词来源。
/// 服务器连不上、服务器上没有文字稿时一律留着手上这份,离线照样能看。
public enum SpokenTranscriptPrecedencePolicy {
    public enum AutomaticServerDecision: Equatable, Sendable {
        /// 照普通歌词的规则:内容变了才换,不拿逐句的换掉逐字的。
        case replaceIfImproved
        /// 直接换掉,哪怕服务器那份的时间轴没有手上这份细。
        case replace
        /// 不动手上这份。
        case keep
    }

    /// 后台从服务器读到一份文字稿时,手上这份怎么办。
    public static func automaticServerDecision(current: [LyricLine]?) -> AutomaticServerDecision {
        switch current.flatMap(SpokenTranscriptOrigin.init(lines:)) {
        case .userProvided?: .keep
        case .generated?: .replace
        case .server?, .other?, nil: .replaceIfImproved
        }
    }

    /// 用户点「重新读取服务器文字稿」时,先问一句再换:手上这份是用户自己编辑或导入的。
    public static func explicitReloadNeedsConfirmation(current: [LyricLine]?) -> Bool {
        current.flatMap(SpokenTranscriptOrigin.init(lines:)) == .userProvided
    }

    /// 生成好的文字稿要不要固定下来:它换掉的是服务器稿,不固定的话下次后台核对又换回去。
    public static func pinsGeneratedTranscript(replacing current: [LyricLine]?) -> Bool {
        current.flatMap(SpokenTranscriptOrigin.init(lines:)) == .server
    }
}

/// 多文件有声书的一个文件读到的文字稿,按这个文件自己的时间算。转写工具有时按整本书的时间
/// 写每一章(第二个文件的第一句写成 01:02:03),也有人给整本书只放一份;这两种都换成文件
/// 自己的时间,不再把前面几个文件的时长加进来。本来就是文件时间的原样不动。
public enum SpokenTranscriptTrackTimeline {
    public typealias Segment = CueTrackLyricsTimelinePolicy.Segment

    /// 书里各文件按阅读顺序排好的时长 → 各自在整本书时间轴上的时间窗。只有一个文件、或有
    /// 文件时长不明(后面的起点就都算不准)时一个都不给。
    public static func segments(durations: [TimeInterval]) -> [Segment?] {
        guard durations.count > 1,
              durations.allSatisfy({ $0.isFinite && $0 > 0 }) else {
            return durations.map { _ in nil }
        }
        var start: TimeInterval = 0
        return durations.enumerated().map { index, duration in
            defer { start += duration }
            let isLast = index == durations.count - 1
            return Segment(start: start, end: isLast ? nil : start + duration, duration: duration)
        }
    }

    /// 文字稿有足够多的行落在这个文件的长度之后,就是按整本书时间写的:只留这个文件时间窗里的行,
    /// 平移到文件开头。逐字时间、行末一起挪。
    public static func localized(_ lines: [LyricLine], in segment: Segment?) -> [LyricLine] {
        guard let segment, segment.duration > 0, segment.start > 0 || segment.end != nil else {
            return lines
        }
        return CueTrackLyricsTimelinePolicy.presenting(lines, in: segment)
    }
}

/// Audiobookshelf 一首音频旁边的几份同名文字稿里挑哪一份、怎么交出去。
public enum AudiobookshelfTranscriptPolicy {
    /// 同名的几份最多读这么多份来比时间轴。
    public static let maximumComparedDocuments = 4

    public struct Document: Equatable, Sendable {
        public let fileName: String
        public let text: String

        public init(fileName: String, text: String) {
            self.fileName = fileName
            self.text = text
        }
    }

    /// 挑时间轴最细的一份(逐字 > 逐行 > 纯文本),一样细的取排在前面的(同名的先于带语言的)。
    /// 给了时间窗(多文件有声书)时换成这个文件自己的时间:换过的交出 ELRC / LRC 文本,没换的原样交出。
    /// 一份都读不出歌词时为 nil。
    public static func pick(_ documents: [Document], segment: CueTrackLyricsTimelinePolicy.Segment?) -> Document? {
        guard let first = documents.first else { return nil }
        // 只有一份、又不用换时间:原文交给读歌词的那一路,那里会再解析一次,这里不白解析一遍。
        if documents.count == 1, segment == nil { return first }
        var best: (index: Int, level: LyricsTimingLevel, lines: [LyricLine])?
        for (index, document) in documents.enumerated() {
            let lines = LyricsContentParser.parseText(document.text)
            guard !lines.isEmpty else { continue }
            let level = LyricsTimingLevel(lines: lines)
            if let current = best, level <= current.level { continue }
            best = (index, level, lines)
        }
        guard let best else { return nil }
        let chosen = documents[best.index]
        let localized = SpokenTranscriptTrackTimeline.localized(best.lines, in: segment)
        guard LyricsDocumentFingerprint(lines: localized) != LyricsDocumentFingerprint(lines: best.lines) else {
            return chosen
        }
        return Document(fileName: chosen.fileName, text: LyricsContentParser.serialize(localized))
    }
}
