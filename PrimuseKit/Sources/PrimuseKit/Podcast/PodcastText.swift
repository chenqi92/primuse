import Foundation

/// feed 里的文本处理。`trimmingCharacters(in:)` 和正则替换在几 KB 的节目说明上很贵(每个元素
/// 结束都要裁一次,几百集的 feed 累积到秒级),这里按 Unicode 标量手写,首尾本来就干净时直接返回原串。
enum PodcastText {
    static func trimmed(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.first, let last = scalars.last else { return text }
        if !first.properties.isWhitespace, !last.properties.isWhitespace { return text }
        guard let start = scalars.firstIndex(where: { !$0.properties.isWhitespace }),
              let end = scalars.lastIndex(where: { !$0.properties.isWhitespace }) else { return "" }
        return String(Substring(scalars[start...end]))
    }

    static func nonEmpty(_ text: String?) -> String? {
        guard let text else { return nil }
        let value = trimmed(text)
        return value.isEmpty ? nil : value
    }

    /// 连续空白(含不换行空格、换行)合成一个空格,不裁首尾。
    static func collapsingWhitespace(_ text: String) -> String {
        var output = String.UnicodeScalarView()
        var previousWasSpace = false
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                if !previousWasSpace { output.append(" ") }
                previousWasSpace = true
            } else {
                output.append(scalar)
                previousWasSpace = false
            }
        }
        return String(output)
    }
}
