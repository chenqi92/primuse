import Foundation

/// 给没有文稿的播客单集、有声书章节生成文稿(#314)用哪一种识别。
public enum SpokenTranscriptEngine: String, Codable, CaseIterable, Sendable {
    /// 本机的 Apple 语音识别(iOS 26 / macOS 26 起):离线、免费、不上传,时长不限。
    case onDevice
    /// Primuse 内置智能(中转的 `transcript_generation`):按 10 分钟一段上传、按段计次。
    case builtIn
    /// 「听歌识词」里设好的 Google 密钥与转写模型:同样分段上传,按 Google 的价格计费。
    case ownKey
    /// 自己的阿里云百炼 API Key:整集一次传到百炼的临时存储,交给 Fun-ASR 录音文件识别,按阿里云的价格计费。
    case aliyun

    /// 要把音频传出去的方式,开始前要用户点头。
    public var uploadsAudio: Bool { self != .onDevice }

    /// 按 10 分钟一段切开上传的方式(内置智能和 Google);阿里云一个文件能收 12 小时,不切。
    public var uploadsInSegments: Bool { self == .builtIn || self == .ownKey }
}

/// 一集太长,上传给转写模型前切成几段。每段最多 `maximumSegmentSeconds` 秒(中转一段最多收
/// 10 分钟),切口前后各多带 `overlap` 秒,免得一个词被切成两半;拼回来时每段只认「开始时间落在
/// 自己负责的区间里」的词。
public struct SpokenTranscriptSegmentPlan: Equatable, Sendable {
    public struct Segment: Equatable, Sendable {
        public var index: Int
        /// 这一段音频在整集里从哪儿到哪儿(含两头的重叠)。
        public var audioStart: TimeInterval
        public var audioEnd: TimeInterval
        /// 这一段负责的区间:开始时间落在这里的词算它的。
        public var keepStart: TimeInterval
        public var keepEnd: TimeInterval

        public var audioDuration: TimeInterval { audioEnd - audioStart }
    }

    /// 中转一段最多 600 秒;留 5 秒余量给编码器补的帧。
    public static let defaultMaximumSegmentSeconds: TimeInterval = 595
    public static let defaultOverlap: TimeInterval = 2

    public var duration: TimeInterval
    public var segments: [Segment]

    public init(
        duration: TimeInterval,
        maximumSegmentSeconds: TimeInterval = defaultMaximumSegmentSeconds,
        overlap: TimeInterval = defaultOverlap
    ) {
        let total = max(0, duration.isFinite ? duration : 0)
        self.duration = total
        let overlap = max(0, min(overlap, maximumSegmentSeconds / 4))
        let keepLimit = max(1, maximumSegmentSeconds - 2 * overlap)
        guard total > 0 else {
            segments = []
            return
        }
        // 一段装得下就不切;要切就平均切,免得最后剩一小截。
        guard total > maximumSegmentSeconds else {
            segments = [Segment(index: 0, audioStart: 0, audioEnd: total, keepStart: 0, keepEnd: total)]
            return
        }
        let count = Int((total / keepLimit).rounded(.up))
        let keepLength = total / Double(count)
        segments = (0..<count).map { index in
            let keepStart = Double(index) * keepLength
            let keepEnd = index == count - 1 ? total : Double(index + 1) * keepLength
            return Segment(
                index: index,
                audioStart: max(0, keepStart - overlap),
                audioEnd: min(total, keepEnd + overlap),
                keepStart: keepStart,
                keepEnd: keepEnd
            )
        }
    }

    /// 把各段的识别结果(时间从这一段音频的开头算)拼成整集的:换成整集的时间,去掉重叠里
    /// 重复的词。段里一个带时间的词都没有时只留它的文字。
    public func stitch(_ results: [Int: AIAudioTranscriptionResult]) -> AIAudioTranscriptionResult {
        var words: [AIAudioTranscriptionWord] = []
        var plainTexts: [String] = []
        for segment in segments {
            guard let result = results[segment.index] else { continue }
            let isLast = segment.index == segments.count - 1
            let timed = result.words.filter { $0.startTime.isFinite && $0.endTime.isFinite }
            if timed.isEmpty {
                let text = result.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { plainTexts.append(text) }
                continue
            }
            for word in timed {
                let start = segment.audioStart + max(0, word.startTime)
                guard start >= segment.keepStart, isLast || start < segment.keepEnd else { continue }
                let end = max(start, segment.audioStart + max(0, word.endTime))
                words.append(AIAudioTranscriptionWord(text: word.text, startTime: start, endTime: min(end, duration > 0 ? max(duration, start) : end)))
            }
        }
        words.sort { $0.startTime == $1.startTime ? $0.endTime < $1.endTime : $0.startTime < $1.startTime }
        let transcript = words.isEmpty
            ? plainTexts.joined(separator: "\n")
            : words.map(\.text).joined(separator: " ")
        return AIAudioTranscriptionResult(transcript: transcript, words: words)
    }
}

/// 识别结果排成文稿。比歌词的一行长一些:一句话一行,太长或停顿久了才断。
public enum SpokenTranscriptLayout {
    public static let maximumLineLength = 64
    public static let maximumLineDuration: TimeInterval = 12

    public static func lines(from result: AIAudioTranscriptionResult) -> [LyricLine] {
        AIAudioTranscriptionLyricsFormatter.document(
            from: result,
            maximumLineLength: maximumLineLength,
            maximumLineDuration: maximumLineDuration
        ).lyricLines()
    }
}

/// 本机识别要先选定一种语言(Apple 的识别不会自己判断语言)。按这个顺序挑:节目自己写的语言、
/// 标题里的文字(汉字、假名、谚文)、设备的首选语言。
public enum SpokenTranscriptLanguagePolicy {
    /// 候选的语言标识,按优先顺序、去重,形如 `en-US`、`zh-CN`。
    public static func candidates(
        declaredLanguage: String?,
        title: String,
        preferredLanguages: [String]
    ) -> [String] {
        var output: [String] = []
        func add(_ value: String?) {
            guard let value, let normalized = normalized(value), !output.contains(normalized) else { return }
            output.append(normalized)
        }
        add(declaredLanguage)
        add(scriptHint(for: title))
        for language in preferredLanguages { add(language) }
        return output
    }

    /// 把 RSS 的 `zh-cn`、`en`、`zh_Hans_CN` 一类写法理成 `zh-CN`、`en`、`zh-Hans-CN`。
    public static func normalized(_ value: String) -> String? {
        let parts = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .split(separator: "-")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard let language = parts.first?.lowercased(),
              (2...3).contains(language.count),
              language.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        var output = [language]
        for part in parts.dropFirst() {
            guard part.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { break }
            switch part.count {
            case 4: output.append(part.prefix(1).uppercased() + part.dropFirst().lowercased())
            case 2, 3: output.append(part.uppercased())
            default: break
            }
        }
        return output.joined(separator: "-")
    }

    /// 标题用的文字能看出的语言;只有拉丁字母时看不出来。
    public static func scriptHint(for text: String) -> String? {
        var han = 0, kana = 0, hangul = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0xAC00...0xD7AF, 0x1100...0x11FF: hangul += 1
            case 0x4E00...0x9FFF, 0x3400...0x4DBF: han += 1
            default: break
            }
        }
        if kana > 0 { return "ja-JP" }
        if hangul > 0 { return "ko-KR" }
        if han > 0 { return "zh-CN" }
        return nil
    }
}

/// 内置智能今天和这个周期的文稿生成段数(用量接口读来的)。上限为 nil 表示套餐没设。
public struct SpokenTranscriptBuiltInAllowance: Equatable, Sendable {
    public var segmentsToday: Int
    public var dailyLimit: Int?
    public var segmentsThisPeriod: Int
    public var periodLimit: Int?

    public init(segmentsToday: Int = 0, dailyLimit: Int? = nil, segmentsThisPeriod: Int = 0, periodLimit: Int? = nil) {
        self.segmentsToday = segmentsToday
        self.dailyLimit = dailyLimit
        self.segmentsThisPeriod = segmentsThisPeriod
        self.periodLimit = periodLimit
    }

    /// 现在还能生成几段:今天和这个周期剩下的取小;都没设上限时为 nil。
    public var remainingSegments: Int? {
        let remaining = [
            dailyLimit.map { max(0, $0 - segmentsToday) },
            periodLimit.map { max(0, $0 - segmentsThisPeriod) },
        ].compactMap { $0 }
        return remaining.min()
    }
}
