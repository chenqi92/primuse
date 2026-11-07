import Foundation

/// 分享文案、文件选择和手填地址共用的输入整理；不改变 URL 内部的转义、签名或查询参数。
public enum MediaImportText {
    public enum Destination: Sendable {
        case playlist, radio, podcast
    }

    public static func destination(for text: String) -> Destination? {
        if isHLS(text) { return .radio }
        switch fileExtension(for: text) {
        case "rss", "atom", "opml": return .podcast
        case "xspf", "wpl", "xml", "json": return .playlist
        case "m3u":
            let rows = lines(text)
            let locations = rows.filter { !$0.hasPrefix("#") }
            guard !locations.isEmpty else { return nil }
            let radioMetadata = rows.contains { row in
                guard row.lowercased().hasPrefix("#extinf:") else { return false }
                let duration = row.dropFirst(8).prefix { $0 != "," && !$0.isWhitespace }
                return Double(duration).map { $0 <= 0 } ?? false
            }
            if radioMetadata, locations.allSatisfy({ normalizedURL($0) != nil }) { return .radio }
            if locations.contains(where: { normalizedURL($0) == nil }) { return .playlist }
            return nil
        default:
            if let url = singleURL(in: text),
               ["opml", "rss", "atom"].contains(url.pathExtension.lowercased())
                || PodcastFeedURL.appleDirectoryID(in: url.absoluteString) != nil { return .podcast }
            return nil
        }
    }
    public static let boundaryCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "\u{FEFF}\u{200B}"))

    public static func cleaned(_ value: String) -> String {
        value.trimmingCharacters(in: boundaryCharacters)
    }

    public static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map(cleaned).filter { !$0.isEmpty }
    }

    public static func decode(_ data: Data) -> String? {
        guard let text = decodeBytes(data), !text.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0) && !CharacterSet.whitespacesAndNewlines.contains($0)
        }) else { return nil }
        return text
    }

    private static func decodeBytes(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        for (bom, encoding) in [
            ([0xFF, 0xFE, 0x00, 0x00], String.Encoding.utf32LittleEndian),
            ([0x00, 0x00, 0xFE, 0xFF], .utf32BigEndian),
            ([0xEF, 0xBB, 0xBF], .utf8),
            ([0xFF, 0xFE], .utf16LittleEndian),
            ([0xFE, 0xFF], .utf16BigEndian),
        ] {
            let prefix = bom.map(UInt8.init)
            if data.starts(with: prefix) {
                return String(data: data.dropFirst(prefix.count), encoding: encoding)
            }
        }
        // 无 BOM 的 UTF-16 不能先试 UTF-8：夹着 NUL 的 ASCII 仍然是合法 UTF-8。
        let sample = Array(data.prefix(128))
        if sample.count >= 8, sample.count.isMultiple(of: 2) {
            let pairs = sample.count / 2
            let evenZeros = stride(from: 0, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            let oddZeros = stride(from: 1, to: sample.count, by: 2).filter { sample[$0] == 0 }.count
            if oddZeros > pairs / 2, evenZeros < pairs / 4 {
                return String(data: data, encoding: .utf16LittleEndian)
            }
            if evenZeros > pairs / 2, oddZeros < pairs / 4 {
                return String(data: data, encoding: .utf16BigEndian)
            }
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        #if canImport(Darwin)
        let gb18030 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if gb18030 != kCFStringEncodingInvalidId,
           let text = String(data: data, encoding: String.Encoding(rawValue: gb18030)) { return text }
        #endif
        return String(data: data, encoding: .windowsCP1252) ?? String(data: data, encoding: .isoLatin1)
    }

    public static func normalizedURL(_ raw: String, allowsBareHost: Bool = false, allowsPodcastScheme: Bool = false, allowsCredentials: Bool = false) -> URL? {
        var value = cleaned(raw)
        if value.hasPrefix("["), let separator = value.range(of: "]("), value.hasSuffix(")") {
            value = cleaned(String(value[separator.upperBound..<value.index(before: value.endIndex)]))
        }
        if value.count >= 2, let first = value.first, let last = value.last,
           (first == "<" && last == ">") || (first == "\"" && last == "\"") || (first == "'" && last == "'") {
            value = cleaned(String(value.dropFirst().dropLast()))
        }
        if allowsPodcastScheme {
            if value.lowercased().hasPrefix("feed:http") { value = String(value.dropFirst(5)) }
            for scheme in ["itpc://", "pcast://", "feed://", "podcast://", "podcasts://"] where value.lowercased().hasPrefix(scheme) {
                value = "https://" + value.dropFirst(scheme.count)
            }
        }
        if allowsBareHost, !value.contains("://"), !value.contains(where: \.isWhitespace) {
            value = "https://" + value
        }
        guard !value.contains(where: \.isNewline),
              let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host, !host.isEmpty,
              !host.contains(where: \.isWhitespace),
              allowsCredentials || (url.user == nil && url.password == nil) else { return nil }
        return url
    }

    /// 从分享说明中提取 URL；保留路径里的逗号、成对括号和完整签名参数。
    public static func urls(in text: String) -> [URL] {
        guard let regex = try? NSRegularExpression(pattern: #"(?i)(?:https?://|(?:itpc|pcast|feed|podcasts?)://)[^\s<>\"'「」【】，。；]+"#) else { return [] }
        let ns = text as NSString
        var seen = Set<String>()
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap { match in
            var raw = ns.substring(with: match.range)
            for (open, close) in [("(", ")"), ("[", "]"), ("（", "）")] {
                while raw.hasSuffix(close), raw.filter({ String($0) == close }).count > raw.filter({ String($0) == open }).count {
                    raw.removeLast()
                }
            }
            guard let url = normalizedURL(raw, allowsPodcastScheme: true), seen.insert(url.absoluteString).inserted else { return nil }
            return url
        }
    }

    public static func singleURL(in text: String, allowsBareHost: Bool = false, allowsPodcastScheme: Bool = false, allowsCredentials: Bool = false) -> URL? {
        if let direct = normalizedURL(text, allowsBareHost: allowsBareHost, allowsPodcastScheme: allowsPodcastScheme, allowsCredentials: allowsCredentials) { return direct }
        let found = urls(in: text)
        return found.count == 1 ? found[0] : nil
    }

    public static func rawContentURL(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host?.lowercased() == "github.com" else { return url }
        var path = components.percentEncodedPath.split(separator: "/").map(String.init)
        guard path.count >= 5, ["blob", "raw"].contains(path[2]) else { return url }
        path.remove(at: 2)
        components.host = "raw.githubusercontent.com"
        components.percentEncodedPath = "/" + path.joined(separator: "/")
        components.query = nil
        components.fragment = nil
        return components.url ?? url
    }

    /// 内容优先，后缀只在没有格式标记时兜底，兼容被网盘改名的文本文件。
    public static func fileExtension(for text: String, suggested: String = "") -> String {
        let head = cleaned(text).prefix(8192).lowercased()
        for (pattern, ext) in [(#"<opml\b"#, "opml"), (#"<rss\b"#, "rss"), (#"<feed\b"#, "atom"),
                               (#"<(?:html|!doctype\s+html)\b"#, "html"), (#"<playlist\b"#, "xspf"),
                               (#"<smil\b"#, "wpl"), (#"<plist\b"#, "xml")] {
            if head.range(of: pattern, options: .regularExpression) != nil { return ext }
        }
        if head.hasPrefix("{") || head.range(of: #"^\[\s*(?:\{|"|\d|\]|true\b|false\b|null\b)"#, options: .regularExpression) != nil { return "json" }
        if head.contains("#extm3u") || head.contains("#extinf:") { return "m3u" }
        if head.contains("[playlist]") || head.range(of: #"(?m)^\s*file\d+\s*="#, options: .regularExpression) != nil { return "pls" }
        return suggested.lowercased()
    }

    public static func isHLS(_ text: String) -> Bool {
        lines(text).contains { $0.uppercased().hasPrefix("#EXT-X-") }
    }

    public static func fileBasename(_ path: String) -> String {
        let value = cleaned(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\", with: "/")
        let decoded = URL(string: value).flatMap { $0.scheme == nil ? nil : $0.path }
            ?? value.removingPercentEncoding ?? value
        return (decoded as NSString).lastPathComponent
    }

    public static func fileBasenames(_ path: String) -> [String] {
        let raw = cleaned(path).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            .replacingOccurrences(of: "\\", with: "/")
        var values = [(raw as NSString).lastPathComponent]
        if let components = URLComponents(string: raw), components.scheme != nil {
            values.append((components.percentEncodedPath as NSString).lastPathComponent)
        }
        values.append(fileBasename(path))
        var seen = Set<String>()
        return values.map { $0.lowercased() }.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    public static func playlistTrackTitle(extInfo: String?, path: String) -> (title: String, artist: String?) {
        var title = (fileBasename(path) as NSString).deletingPathExtension
        if let extInfo {
            var quote: Character?
            var separator: String.Index?
            for index in extInfo.indices {
                let character = extInfo[index]
                if let open = quote {
                    if character == open { quote = nil }
                } else if character == "\"" || character == "'" { quote = character }
                else if character == "," { separator = index; break }
            }
            if let separator = separator ?? extInfo.firstIndex(of: ",") {
                let explicit = cleaned(String(extInfo[extInfo.index(after: separator)...]))
                if !explicit.isEmpty { title = explicit }
            }
        }
        if let dash = title.range(of: " - ") {
            let artist = cleaned(String(title[..<dash.lowerBound]))
            let song = cleaned(String(title[dash.upperBound...]))
            if !artist.isEmpty, !song.isEmpty { return (song, artist) }
        }
        return (title, nil)
    }
}
