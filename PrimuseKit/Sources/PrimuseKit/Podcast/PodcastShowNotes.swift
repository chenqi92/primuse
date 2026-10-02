import Foundation

/// 节目说明(多半是 HTML)整理成界面能直接排版的段落。
///
/// 不走系统的 HTML → 富文本(要在主线程跑 WebKit,长说明会卡),自己做一个只认段落、换行、
/// 列表、标题、粗体斜体和链接的小转换器;正文里的 `12:34` / `1:02:03` 认成时间点,点了能跳过去。
public enum PodcastShowNotes {
    public enum Run: Sendable, Hashable {
        case text(String, bold: Bool, italic: Bool)
        case link(String, URL)
        case timestamp(String, TimeInterval)
    }

    public enum Block: Sendable, Hashable {
        case paragraph([Run])
        case heading([Run])
        case listItem([Run], marker: String)
        case quote([Run])
    }

    /// 时间点链接用的地址形式:`primuse-podcast-seek://<秒>`。界面拦下这个协议去跳转。
    public static let seekScheme = "primuse-podcast-seek"

    public static func seekURL(_ seconds: TimeInterval) -> URL {
        URL(string: "\(seekScheme)://\(Int(seconds.rounded(.down)))")!
    }

    public static func seekSeconds(from url: URL) -> TimeInterval? {
        guard url.scheme == seekScheme, let host = url.host, let value = Int(host), value >= 0 else { return nil }
        return TimeInterval(value)
    }

    // MARK: - Plain text

    /// 列表行里那一两行摘要:去标签、解实体、合并空白。单遍扫描,读够 `limit` 个字就停 ——
    /// 几百集的列表每行都要算一次,不能每次把整段说明排一遍版。
    public static func plainSummary(_ raw: String?, limit: Int = 280) -> String? {
        guard let raw, !raw.isEmpty, limit > 0 else { return nil }
        let scalars = Array(raw.unicodeScalars)
        var output = String.UnicodeScalarView()
        var visible = 0
        var pendingSpace = false
        var skippingUntil: String?
        var index = 0
        var truncated = false

        func emit(_ scalar: Unicode.Scalar) {
            if scalar.properties.isWhitespace {
                pendingSpace = true
                return
            }
            if pendingSpace, !output.isEmpty { output.append(" ") }
            pendingSpace = false
            output.append(scalar)
            visible += 1
        }

        while index < scalars.count {
            if visible >= limit {
                truncated = scalars[index...].contains { !$0.properties.isWhitespace && $0 != "<" }
                break
            }
            let scalar = scalars[index]
            if scalar == "<", index + 1 < scalars.count,
               scalars[index + 1].properties.isAlphabetic || scalars[index + 1] == "/" || scalars[index + 1] == "!" {
                var close = index + 1
                while close < scalars.count, scalars[close] != ">" { close += 1 }
                var name = String.UnicodeScalarView()
                var cursor = index + 1
                if cursor < scalars.count, scalars[cursor] == "/" {
                    name.append("/")
                    cursor += 1
                }
                while cursor < close, scalars[cursor].properties.isAlphabetic || ("0"..."9").contains(scalars[cursor]) {
                    name.append(scalars[cursor])
                    cursor += 1
                }
                let tag = String(name).lowercased()
                if let target = skippingUntil {
                    if tag == target { skippingUntil = nil }
                } else if tag == "script" || tag == "style" {
                    skippingUntil = "/" + tag
                } else {
                    // 块级标签和换行之间留一个空格,行内标签不留。
                    let bare = tag.hasPrefix("/") ? String(tag.dropFirst()) : tag
                    if Self.blockTags.contains(bare) { pendingSpace = true }
                }
                index = min(close + 1, scalars.count)
                continue
            }
            if skippingUntil != nil {
                index += 1
                continue
            }
            if scalar == "&" {
                var end = index + 1
                while end < scalars.count, end - index <= 10, scalars[end] != ";", scalars[end] != "&" { end += 1 }
                if end < scalars.count, scalars[end] == ";" {
                    let name = String(String.UnicodeScalarView(scalars[(index + 1)..<end]))
                    if let value = entityScalar(name), let decoded = Unicode.Scalar(value) {
                        emit(decoded)
                        index = end + 1
                        continue
                    }
                }
            }
            emit(scalar)
            index += 1
        }
        let text = String(output)
        guard !text.isEmpty else { return nil }
        return truncated ? text + "…" : text
    }

    private static let blockTags: Set<String> = [
        "p", "br", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "tr", "td", "section", "hr",
    ]

    // MARK: - Blocks

    public static func blocks(from raw: String) -> [Block] {
        let source = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { return [] }
        if !looksLikeHTML(source) { return plainTextBlocks(source) }
        var builder = BlockBuilder()
        var index = source.startIndex
        while index < source.endIndex {
            let character = source[index]
            if character == "<", let close = source[index...].firstIndex(of: ">") {
                let tag = String(source[source.index(after: index)..<close])
                builder.handleTag(tag)
                index = source.index(after: close)
                continue
            }
            let next = source[index...].firstIndex(of: "<") ?? source.endIndex
            builder.appendText(decodeEntities(String(source[index..<next])))
            index = next
        }
        builder.flush()
        return builder.blocks
    }

    private static func looksLikeHTML(_ text: String) -> Bool {
        text.range(of: "<\\s*/?\\s*(p|br|div|a|ul|ol|li|strong|b|em|i|h[1-6]|span|blockquote)\\b", options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func plainTextBlocks(_ text: String) -> [Block] {
        let normalized = decodeEntities(text).replacingOccurrences(of: "\r\n", with: "\n")
        return normalized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { line in
                let runs = linkified(line, bold: false, italic: false)
                if let marker = listMarker(in: line) {
                    return .listItem(linkified(String(line.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces), bold: false, italic: false), marker: "•")
                }
                return .paragraph(runs)
            }
    }

    private static func listMarker(in line: String) -> String? {
        for marker in ["- ", "• ", "* ", "· "] where line.hasPrefix(marker) { return marker }
        return nil
    }

    // MARK: - Inline detection

    /// 一段纯文本里的网址和时间点。
    static func linkified(_ text: String, bold: Bool, italic: Bool) -> [Run] {
        guard !text.isEmpty else { return [] }
        var runs: [Run] = []
        var buffer = ""
        let matches = inlineMatches(in: text)
        var cursor = text.startIndex
        for match in matches {
            if cursor < match.range.lowerBound { buffer += text[cursor..<match.range.lowerBound] }
            if !buffer.isEmpty {
                runs.append(.text(buffer, bold: bold, italic: italic))
                buffer = ""
            }
            runs.append(match.run)
            cursor = match.range.upperBound
        }
        if cursor < text.endIndex { buffer += text[cursor...] }
        if !buffer.isEmpty { runs.append(.text(buffer, bold: bold, italic: italic)) }
        return runs
    }

    private struct InlineMatch {
        let range: Range<String.Index>
        let run: Run
    }

    private static func inlineMatches(in text: String) -> [InlineMatch] {
        var matches: [InlineMatch] = []
        // 网址
        var searchStart = text.startIndex
        while let range = text.range(of: "https?://[^\\s<>\"'，。、）)】]+", options: [.regularExpression, .caseInsensitive], range: searchStart..<text.endIndex) {
            var end = range.upperBound
            // 句末标点不算进网址。
            while end > range.lowerBound, let last = text[range.lowerBound..<end].last, ".,;:!?".contains(last) {
                end = text.index(before: end)
            }
            let literal = String(text[range.lowerBound..<end])
            if let url = URL(string: literal) {
                matches.append(InlineMatch(range: range.lowerBound..<end, run: .link(literal, url)))
            }
            searchStart = range.upperBound
        }
        // 时间点
        searchStart = text.startIndex
        while let range = text.range(of: "(?<![\\d:])(\\d{1,2}:)?\\d{1,3}:\\d{2}(?![\\d:])", options: .regularExpression, range: searchStart..<text.endIndex) {
            searchStart = range.upperBound
            guard !matches.contains(where: { $0.range.overlaps(range) }) else { continue }
            let literal = String(text[range])
            if let seconds = timestamp(literal) {
                matches.append(InlineMatch(range: range, run: .timestamp(literal, seconds)))
            }
        }
        return matches.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// `MM:SS` 或 `H:MM:SS`,秒和分(带小时时)必须小于 60。
    public static func timestamp(_ literal: String) -> TimeInterval? {
        let parts = literal.split(separator: ":").map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2:
            guard values[1] < 60 else { return nil }
            return TimeInterval(values[0] * 60 + values[1])
        case 3:
            guard values[1] < 60, values[2] < 60 else { return nil }
            return TimeInterval(values[0] * 3600 + values[1] * 60 + values[2])
        default:
            return nil
        }
    }

    // MARK: - Entities

    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var output = ""
        output.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&" else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let rest = text[text.index(after: index)...]
            guard let semicolon = rest.prefix(10).firstIndex(of: ";") else {
                output.append(character)
                index = text.index(after: index)
                continue
            }
            let name = String(rest[rest.startIndex..<semicolon])
            if let scalar = entityScalar(name), let unicode = Unicode.Scalar(scalar) {
                output.unicodeScalars.append(unicode)
                index = text.index(after: semicolon)
            } else {
                output.append(character)
                index = text.index(after: index)
            }
        }
        return output
    }

    private static func entityScalar(_ name: String) -> UInt32? {
        switch name {
        case "amp": return 38
        case "lt": return 60
        case "gt": return 62
        case "quot": return 34
        case "apos": return 39
        default: break
        }
        if name.hasPrefix("#x") || name.hasPrefix("#X") { return UInt32(name.dropFirst(2), radix: 16) }
        if name.hasPrefix("#") { return UInt32(name.dropFirst()) }
        return PodcastFeedParser.htmlEntities[name]
    }

    // MARK: - Builder

    private struct BlockBuilder {
        enum Kind { case paragraph, heading, listItem(String), quote }

        var blocks: [Block] = []
        private var runs: [Run] = []
        private var kind: Kind = .paragraph
        private var boldDepth = 0
        private var italicDepth = 0
        private var link: (url: URL, text: String)?
        private var listStack: [(ordered: Bool, counter: Int)] = []
        private var skipDepth = 0
        private var quoteDepth = 0

        mutating func appendText(_ raw: String) {
            guard skipDepth == 0 else { return }
            // HTML 里的换行和连续空白只算一个空格。
            let collapsed = PodcastText.collapsingWhitespace(raw)
            guard !collapsed.isEmpty else { return }
            if link != nil {
                link?.text += collapsed
                return
            }
            let leadingTrimmed = runs.isEmpty ? String(collapsed.drop(while: { $0 == " " })) : collapsed
            guard !leadingTrimmed.isEmpty else { return }
            runs.append(contentsOf: PodcastShowNotes.linkified(leadingTrimmed, bold: boldDepth > 0, italic: italicDepth > 0))
        }

        mutating func handleTag(_ rawTag: String) {
            let trimmed = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.hasPrefix("!") else { return }
            let isClosing = trimmed.hasPrefix("/")
            let body = isClosing ? String(trimmed.dropFirst()) : trimmed
            let name = body.prefix { $0.isLetter || $0.isNumber }.lowercased()

            if ["script", "style", "head", "title"].contains(name) {
                if isClosing { skipDepth = max(0, skipDepth - 1) } else if !trimmed.hasSuffix("/") { skipDepth += 1 }
                return
            }
            guard skipDepth == 0 else { return }

            switch name {
            case "p", "div", "section", "article", "header", "footer", "figure", "table", "tr":
                flush()
            case "br":
                flush()
            case "h1", "h2", "h3", "h4", "h5", "h6":
                flush()
                kind = isClosing ? .paragraph : .heading
            case "blockquote":
                flush()
                quoteDepth = max(0, quoteDepth + (isClosing ? -1 : 1))
                kind = quoteDepth > 0 ? .quote : .paragraph
            case "ul", "ol":
                flush()
                if isClosing { _ = listStack.popLast() } else { listStack.append((name == "ol", 0)) }
            case "li":
                flush()
                if !isClosing {
                    if listStack.isEmpty { listStack.append((false, 0)) }
                    listStack[listStack.count - 1].counter += 1
                    let level = listStack[listStack.count - 1]
                    kind = .listItem(level.ordered ? "\(level.counter)." : "•")
                } else {
                    kind = quoteDepth > 0 ? .quote : .paragraph
                }
            case "strong", "b":
                boldDepth = max(0, boldDepth + (isClosing ? -1 : 1))
            case "em", "i":
                italicDepth = max(0, italicDepth + (isClosing ? -1 : 1))
            case "a":
                if isClosing {
                    closeLink()
                } else if let href = Self.attribute("href", in: body),
                          let url = URL(string: PodcastShowNotes.decodeEntities(href).trimmingCharacters(in: .whitespaces)),
                          let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) {
                    closeLink()
                    link = (url, "")
                }
            default:
                break
            }
        }

        private mutating func closeLink() {
            guard let open = link else { return }
            link = nil
            let text = open.text.trimmingCharacters(in: .whitespaces)
            if text.isEmpty { return }
            if let seconds = PodcastShowNotes.timestamp(text), open.url.host == nil {
                runs.append(.timestamp(text, seconds))
            } else {
                runs.append(.link(text, open.url))
            }
        }

        mutating func flush() {
            closeLink()
            // 去掉段尾空白
            if case .text(let last, let bold, let italic)? = runs.last {
                let trimmed = String(last.reversed().drop(while: { $0 == " " }).reversed())
                if trimmed.isEmpty { runs.removeLast() } else { runs[runs.count - 1] = .text(trimmed, bold: bold, italic: italic) }
            }
            guard !runs.isEmpty else { return }
            switch kind {
            case .paragraph: blocks.append(.paragraph(runs))
            case .heading: blocks.append(.heading(runs))
            case .listItem(let marker): blocks.append(.listItem(runs, marker: marker))
            case .quote: blocks.append(.quote(runs))
            }
            runs = []
        }

        static func attribute(_ name: String, in tagBody: String) -> String? {
            let pattern = "\\b\(name)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: tagBody, range: NSRange(tagBody.startIndex..., in: tagBody)) else { return nil }
            for group in 2...4 {
                if let range = Range(match.range(at: group), in: tagBody) { return String(tagBody[range]) }
            }
            return nil
        }
    }
}

public extension PodcastShowNotes.Run {
    var plainText: String {
        switch self {
        case .text(let text, _, _): return text
        case .link(let text, _): return text
        case .timestamp(let text, _): return text
        }
    }
}
