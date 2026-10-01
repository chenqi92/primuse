import Foundation
import PrimuseKit

enum LyricsParser {
    static func parse(_ content: String) -> [LyricLine] {
        LyricsContentParser.parseText(content)
    }

    static func parse(from url: URL) throws -> [LyricLine] {
        let data = try Data(contentsOf: url)
        guard let content = decodeText(data, label: url.lastPathComponent) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return parse(content)
    }

    /// 歌词文件的字节 → 文本。不只认 UTF-8:GBK / Big5 / Shift_JIS / 无 BOM 的 UTF-16
    /// 都按 `TextEncodingRepair.decodeTextFile` 认出来;不是 UTF-8 时记一笔,便于区分
    /// 「解码错」和「繁简判定错」。
    static func decodeText(_ data: Data, label: String) -> String? {
        guard let decoded = TextEncodingRepair.decodeTextFile(data) else { return nil }
        if decoded.encoding != .utf8 {
            plog("📜 lyrics decoded as \(decoded.encodingName) (\(label))")
        }
        return decoded.text
    }

    static func parseText(_ text: String) -> [LyricLine] {
        LyricsContentParser.parseText(text)
    }
}
