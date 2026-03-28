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
}
