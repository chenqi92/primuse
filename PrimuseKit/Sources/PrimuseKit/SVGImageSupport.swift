import Foundation

/// SVG 字节的识别。
///
/// ImageIO 解不了 SVG，所以矢量台标要走另一条栅格化的路。判定放在这里而不是
/// 跟着栅格化器走：识别是纯字节判断，各平台一致，也能单独验；栅格化依赖
/// CoreGraphics 和第三方解析器，只活在 app 层。
///
/// 判定刻意做得严：只认「根元素就是 `<svg>`」的文档。网上抓回来的 404 页面里
/// 常常内嵌一个 `<svg>` 图标，光看「有没有出现 <svg」会把整张错误页当成台标。
public enum SVGImageSupport {
    /// 矢量台标就是一段文本，正常不会超过这个大小。再大多半是被塞了内嵌位图，
    /// 那还不如让它当普通图片走失败路径。
    public static let maximumBytes = 2 * 1_024 * 1_024

    /// 只读这么多字节来判断根元素。声明、注释、DOCTYPE 加起来不会比这更长。
    private static let inspectionPrefixBytes = 4_096

    /// 根元素是不是 `<svg>`。
    public static func looksLikeSVG(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= maximumBytes else { return false }
        var scanner = Array(data.prefix(inspectionPrefixBytes))
        // UTF-8 BOM
        if scanner.count >= 3, scanner[0] == 0xEF, scanner[1] == 0xBB, scanner[2] == 0xBF {
            scanner.removeFirst(3)
        }
        var index = 0

        func skipWhitespace() {
            while index < scanner.count, isWhitespace(scanner[index]) { index += 1 }
        }

        func skip(untilAfter terminator: [UInt8]) -> Bool {
            var cursor = index
            while cursor + terminator.count <= scanner.count {
                if Array(scanner[cursor..<(cursor + terminator.count)]) == terminator {
                    index = cursor + terminator.count
                    return true
                }
                cursor += 1
            }
            return false
        }

        while true {
            skipWhitespace()
            guard index < scanner.count, scanner[index] == UInt8(ascii: "<") else { return false }
            let next = index + 1 < scanner.count ? scanner[index + 1] : 0

            if next == UInt8(ascii: "?") {
                // `<?xml …?>`
                index += 2
                guard skip(untilAfter: [UInt8(ascii: "?"), UInt8(ascii: ">")]) else { return false }
                continue
            }
            if next == UInt8(ascii: "!") {
                // `<!-- … -->` 或 `<!DOCTYPE …>`
                if matches(scanner, at: index, "<!--") {
                    index += 4
                    guard skip(untilAfter: [
                        UInt8(ascii: "-"), UInt8(ascii: "-"), UInt8(ascii: ">"),
                    ]) else { return false }
                } else {
                    index += 2
                    guard skip(untilAfter: [UInt8(ascii: ">")]) else { return false }
                }
                continue
            }
            // 第一个真正的元素必须是 svg，且 `<svg` 后面得是分隔符，
            // 否则 `<svgfoo>` 这种也会被认下来。
            guard matches(scanner, at: index, "<svg") else { return false }
            let after = index + 4 < scanner.count ? scanner[index + 4] : UInt8(ascii: ">")
            return isWhitespace(after)
                || after == UInt8(ascii: ">")
                || after == UInt8(ascii: "/")
        }
    }

    /// 是不是一份**完整**的 SVG。下载被截断时前半段照样能通过根元素判定，
    /// 但存下来就是一张永远画不全的图。
    public static func isCompleteSVG(_ data: Data) -> Bool {
        guard looksLikeSVG(data) else { return false }
        let tail = Array(data.suffix(256))
        var end = tail.count
        while end > 0, isWhitespace(tail[end - 1]) { end -= 1 }
        let closing = Array("</svg>".utf8)
        guard end >= closing.count else { return false }
        return Array(tail[(end - closing.count)..<end]).map(lowercased) == closing
    }

    /// 地址看起来是不是指向一张 SVG。用于「这个链接值不值得当台标」的判断，
    /// 拿不到字节时只能靠它。
    public static func referenceLooksLikeSVG(_ urlString: String?) -> Bool {
        guard let urlString, let url = URL(string: urlString) else { return false }
        if url.pathExtension.lowercased() == "svg" { return true }
        let query = url.query?.lowercased() ?? ""
        return query.contains("=svg")
    }

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }

    private static func matches(_ bytes: [UInt8], at index: Int, _ token: String) -> Bool {
        let expected = Array(token.utf8).map(lowercased)
        guard index + expected.count <= bytes.count else { return false }
        return Array(bytes[index..<(index + expected.count)]).map(lowercased) == expected
    }
}
