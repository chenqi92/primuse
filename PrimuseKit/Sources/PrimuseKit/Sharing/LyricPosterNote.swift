import Foundation

/// 用户写在海报上的一段话。歌词是别人的，这段是自己的 —— 海报上它排在
/// 歌词下方，字号更小，用手写感的字体，像写在明信片背面。
public struct LyricPosterNote: Hashable, Sendable {
    public let text: String
    /// 落款。空着就不画那一行。
    public let signature: String?

    public init(text: String, signature: String? = nil) {
        self.text = text
        self.signature = signature
    }

    public var isEmpty: Bool { text.isEmpty }
}

public enum LyricPosterNotePolicy {
    /// 一段感想的上限。再长就不是"一句话"，海报也放不下。
    public static let maximumLength = 120
    /// 落款的上限。
    public static let maximumSignatureLength = 24
    /// 评语字号占画布宽度的比例。固定下来，才能在排歌词之前就把它占的
    /// 高度算出来 —— 否则字号与高度互相依赖，解不出来。
    public static let fontSizeRatio: Double = 0.030
    private static let lineHeightFactor: Double = 1.5

    /// 规范化用户输入：去掉首尾空白、把连续空行压成一个换行、截到上限。
    ///
    /// 截断按字符（Character）而不是 UTF-16 单元，否则一个 emoji 会被从
    /// 中间切开。
    public static func sanitized(_ raw: String, limit: Int = maximumLength) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined(separator: "\n")
        var trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.contains("\n\n") {
            trimmed = trimmed.replacingOccurrences(of: "\n\n", with: "\n")
        }
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit))
    }

    public static func sanitizedSignature(_ raw: String) -> String {
        sanitized(raw, limit: maximumSignatureLength)
            .replacingOccurrences(of: "\n", with: " ")
    }

    /// 还能再写几个字。负数说明已经超了（UI 上用来变红）。
    public static func remaining(for raw: String, limit: Int = maximumLength) -> Int {
        limit - raw.count
    }

    public static func note(text: String, signature: String) -> LyricPosterNote? {
        let body = sanitized(text)
        guard !body.isEmpty else { return nil }
        let mark = sanitizedSignature(signature)
        return LyricPosterNote(text: body, signature: mark.isEmpty ? nil : mark)
    }

    /// 评语块在海报上占的高度，含它与歌词之间的间距。
    ///
    /// 风格把这个值计进自己的 `reservedHeight`，歌词的字号搜索才知道
    /// 上面少了多少地方可用。
    public static func estimatedHeight(
        of note: LyricPosterNote?,
        canvasWidth: Double,
        textWidth: Double
    ) -> Double {
        guard let note, !note.isEmpty, canvasWidth > 0, textWidth > 0 else { return 0 }
        let fontSize = canvasWidth * fontSizeRatio
        let rows = LyricPosterLayoutPolicy.wrappedRowCount(
            of: note.text,
            fontSize: fontSize,
            textWidth: textWidth
        )
        // 手写换行也要算进去：用户敲的每个回车都是新的一行。
        let explicitBreaks = note.text.reduce(0) { $0 + ($1 == "\n" ? 1 : 0) }
        var height = Double(rows + explicitBreaks) * fontSize * lineHeightFactor
        if note.signature?.isEmpty == false {
            height += fontSize * lineHeightFactor
        }
        // 与歌词之间留一道空。
        height += fontSize * 1.4
        return height
    }
}
