import Foundation
import PrimuseKit

enum LyricsParser {
    static func parse(_ content: String) -> [LyricLine] {
        LyricsContentParser.parseText(content)
    }

    static func parse(from url: URL) throws -> [LyricLine] {
        let content = try String(contentsOf: url, encoding: .utf8)
        return parse(content)
    }

    static func parseText(_ text: String) -> [LyricLine] {
        LyricsContentParser.parseText(text)
    }
}
