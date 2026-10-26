import Foundation

/// 歌词、文字稿存成文件时的格式(#362)。
public enum LyricsExportFormat: String, CaseIterable, Sendable, Identifiable {
    /// 带时间的 LRC,逐字时间写成增强 LRC,自带的译文跟在同一时间戳下。
    case lrc
    /// SRT 字幕,视频编辑和字幕工具都认。
    case srt
    /// 纯文本,不带时间。
    case plainText

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .lrc: "lrc"
        case .srt: "srt"
        case .plainText: "txt"
        }
    }

    /// 要有时间轴才写得出来。
    public var needsTiming: Bool { self != .plainText }
}

/// 把正在用的歌词或文字稿(听歌识词、生成文字稿的结果也在其中)写成文件。
///
/// 有一行带时间才给 LRC 与 SRT;一个字都没有时什么都不给。文字稿的纯文本按停顿并成段落
/// (和全屏读文稿同一套规矩),歌词照原样一行一行写。
public enum LyricsExportPolicy {
    /// 没有结束时间、后面也没有下一行时,一行字幕按字数估的显示时长:至少这么久……
    static let minimumCueDuration: TimeInterval = 3
    /// ……每个字最多算这么久,下一行隔了很久时字幕不一直挂着。
    static let secondsPerCharacter: TimeInterval = 0.6

    /// 能存成哪几种格式,按菜单里的先后。
    public static func formats(for lines: [LyricLine]) -> [LyricsExportFormat] {
        let worded = lines.filter { !trimmed($0.text).isEmpty }
        guard !worded.isEmpty else { return [] }
        return worded.contains(where: \.isSynchronized) ? [.lrc, .srt, .plainText] : [.plainText]
    }

    /// 文件内容;这种格式写不出来时是 nil。
    /// - Parameter readsAsProse: 文字稿(有声书、播客):纯文本并成段落,段与段之间空一行。
    public static func render(
        _ lines: [LyricLine],
        as format: LyricsExportFormat,
        readsAsProse: Bool
    ) -> String? {
        guard formats(for: lines).contains(format) else { return nil }
        let flattened = LyricVoiceTimelinePolicy.flattenedLines(lines)
        switch format {
        case .lrc:
            return LyricsContentParser.serialize(flattened) + "\n"
        case .srt:
            return subRip(flattened)
        case .plainText:
            return plainText(flattened, readsAsProse: readsAsProse)
        }
    }

    /// 文件名:「标题 - 艺人.扩展名」,去掉文件系统不认的字符。
    public static func fileName(title: String, artist: String?, format: LyricsExportFormat) -> String {
        AudioClipExportPolicy.fileName(title: title, artist: artist, fileExtension: format.fileExtension)
    }

    // MARK: - SRT

    static func subRip(_ lines: [LyricLine]) -> String? {
        // 同一时刻的几行保持原来的先后。
        let timed = lines.enumerated()
            .filter { $0.element.isSynchronized && $0.element.timestamp.isFinite }
            .sorted { ($0.element.timestamp, $0.offset) < ($1.element.timestamp, $1.offset) }
            .map(\.element)
        var cues: [String] = []
        for (index, line) in timed.enumerated() {
            let text = cueText(line)
            guard !text.isEmpty else { continue }
            let start = max(0, line.timestamp)
            // 空行(间奏)也是边界:上一行唱到这里就该收起。
            let next = timed[(index + 1)...].first { $0.timestamp > start }?.timestamp
            var end: TimeInterval
            if let explicit = line.endTime, explicit.isFinite, explicit > start {
                end = explicit
            } else {
                let estimate = start + max(minimumCueDuration, Double(text.count) * secondsPerCharacter)
                end = min(next ?? estimate, estimate)
            }
            if end <= start { end = start + minimumCueDuration }
            cues.append("\(cues.count + 1)\n\(timecode(start)) --> \(timecode(end))\n\(text)")
        }
        guard !cues.isEmpty else { return nil }
        return cues.joined(separator: "\n\n") + "\n"
    }

    /// 一条字幕的字:原文,自带译文时另起一行跟在下面。
    private static func cueText(_ line: LyricLine) -> String {
        var rows = [singleLine(line.text)]
        if let translation = line.manualTranslation.map({ singleLine($0.text) }), !translation.isEmpty {
            rows.append(translation)
        }
        return rows.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    /// SRT 里空行是字幕之间的分隔,一条字幕内部不能有空行。
    private static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline)
            .map { trimmed(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `HH:MM:SS,mmm`。
    static func timecode(_ seconds: TimeInterval) -> String {
        let totalMilliseconds = Int((max(0, seconds) * 1000).rounded())
        let milliseconds = totalMilliseconds % 1000
        let totalSeconds = totalMilliseconds / 1000
        return String(
            format: "%02d:%02d:%02d,%03d",
            totalSeconds / 3600,
            (totalSeconds / 60) % 60,
            totalSeconds % 60,
            milliseconds
        )
    }

    // MARK: - Plain text

    static func plainText(_ lines: [LyricLine], readsAsProse: Bool) -> String? {
        let body: String
        if readsAsProse {
            let cues = lines.map { line in
                SpokenWordTranscriptReadingPolicy.Cue(
                    text: line.text,
                    start: line.isSynchronized ? line.timestamp : nil,
                    end: line.isSynchronized ? line.endTime : nil,
                    speaker: line.voice.rawValue
                )
            }
            body = SpokenWordTranscriptReadingPolicy.paragraphs(from: cues)
                .map { trimmed($0.text) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        } else {
            // 一行一行照写;连着的空行(间奏、段落之间)只留一个。
            var rows: [String] = []
            for line in lines {
                let text = trimmed(line.text)
                if text.isEmpty {
                    if let last = rows.last, !last.isEmpty { rows.append("") }
                } else {
                    rows.append(text)
                }
            }
            while rows.last?.isEmpty == true { rows.removeLast() }
            body = rows.joined(separator: "\n")
        }
        guard !body.isEmpty else { return nil }
        return body + "\n"
    }

    private static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
