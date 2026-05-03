import Foundation
import PrimuseKit

enum LyricsParser {
    /// 行首时间戳（含行级 LRC 头）。Regex 字面量只读、纯函数，多线程读取安全。
    nonisolated(unsafe) private static let lineHeadPattern = /\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]/
    /// A2 扩展字级标记 `<mm:ss.xx>`
    nonisolated(unsafe) private static let inlineWordPattern = /<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>/

    /// 解析 LRC 内容。自动识别行级 (`[mm:ss.xx]text`) 与逐字 (`[mm:ss.xx]<mm:ss.xx>w<mm:ss.xx>w...`) 两种格式。
    static func parse(_ content: String) -> [LyricLine] {
        var lines: [LyricLine] = []

        for raw in content.components(separatedBy: .newlines) {
            // 一行可能挂多个行首时间戳：`[00:01.23][00:45.67]text`，全部展开
            let heads = raw.matches(of: lineHeadPattern)
            guard !heads.isEmpty else { continue }

            // 取最后一个行首时间戳之后的内容作为正文
            let bodyStart = heads.last!.range.upperBound
            let body = String(raw[bodyStart...])

            for head in heads {
                let lineStart = parseTimestamp(min: head.1, sec: head.2, frac: head.3)
                if let parsed = parseWordLevelLine(body: body, lineStart: lineStart) {
                    lines.append(parsed)
                } else {
                    let text = body.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { continue }
                    lines.append(LyricLine(timestamp: lineStart, text: text))
                }
            }
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    /// 把行 body 解析为 syllables；不含字级标记时返回 nil。
    private static func parseWordLevelLine(body: String, lineStart: TimeInterval) -> LyricLine? {
        let marks = body.matches(of: inlineWordPattern)
        guard !marks.isEmpty else { return nil }

        var syllables: [LyricSyllable] = []
        for (i, mark) in marks.enumerated() {
            let start = parseTimestamp(min: mark.1, sec: mark.2, frac: mark.3)
            let textStart = mark.range.upperBound
            let textEnd = (i + 1 < marks.count) ? marks[i + 1].range.lowerBound : body.endIndex
            let chunk = String(body[textStart..<textEnd])

            // 行尾压轴的时间戳（最后一个 mark 之后无文字）= 行 end，不算独立字
            if chunk.isEmpty {
                if let last = syllables.last {
                    syllables[syllables.count - 1] = LyricSyllable(
                        text: last.text, start: last.start, end: max(last.end, start)
                    )
                }
                continue
            }
            syllables.append(LyricSyllable(text: chunk, start: start, end: start))
        }

        guard !syllables.isEmpty else { return nil }

        // 后处理：每字 end = 下一字 start；最后一字若没有压轴时间戳，沿用 start（渲染时再兜底）
        for i in 0..<(syllables.count - 1) {
            syllables[i].end = max(syllables[i].end, syllables[i + 1].start)
        }
        if syllables.last!.end <= syllables.last!.start {
            syllables[syllables.count - 1].end = syllables.last!.start + 0.4
        }

        let plain = syllables.map(\.text).joined()
        let trimmed = plain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        return LyricLine(timestamp: lineStart, text: plain, syllables: syllables)
    }

    private static func parseTimestamp(min: Substring, sec: Substring, frac: Substring?) -> TimeInterval {
        let m = Double(min) ?? 0
        let s = Double(sec) ?? 0
        let f = Double(frac ?? "0") ?? 0
        let divisor: Double = (frac?.count ?? 0) == 3 ? 1000 : 100
        return m * 60 + s + f / divisor
    }

    /// Parses LRC file from URL
    static func parse(from url: URL) throws -> [LyricLine] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content)
    }

    /// Parses plain text lyrics (non-LRC) or embedded LRC content.
    /// If the text contains LRC timestamps, parses as LRC; otherwise treats each line as a lyric line.
    static func parseText(_ text: String) -> [LyricLine] {
        let lrcResult = parse(text)
        if !lrcResult.isEmpty { return lrcResult }

        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(timestamp: 0, text: $0.element) }
    }
}
