import Foundation
import PrimuseKit

enum LyricsParser {
    /// Parses LRC format lyrics: [mm:ss.xx]text
    static func parse(_ content: String) -> [LyricLine] {
        let pattern = /\[(\d{1,2}):(\d{2})(?:\.(\d{1,3}))?\](.*)/

        var lines: [LyricLine] = []

        for line in content.components(separatedBy: .newlines) {
            guard let match = line.firstMatch(of: pattern) else { continue }

            let minutes = Double(match.1) ?? 0
            let seconds = Double(match.2) ?? 0
            let centiseconds = Double(match.3 ?? "0") ?? 0

            let divisor: Double = (match.3?.count ?? 0) == 3 ? 1000 : 100
            let timestamp = minutes * 60 + seconds + centiseconds / divisor

            let text = String(match.4).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }

            lines.append(LyricLine(timestamp: timestamp, text: text))
        }

        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    /// Parses LRC file from URL
    static func parse(from url: URL) throws -> [LyricLine] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content)
    }

    /// Parses plain text lyrics (non-LRC) or embedded LRC content.
    /// If the text contains LRC timestamps, parses as LRC; otherwise treats each line as a lyric line.
    static func parseText(_ text: String) -> [LyricLine] {
        // Check if text contains LRC timestamps
        let lrcResult = parse(text)
        if !lrcResult.isEmpty { return lrcResult }

        // Plain text: each non-empty line becomes a lyric line (no timestamps)
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated()
            .map { LyricLine(timestamp: 0, text: $0.element) }
    }
}
