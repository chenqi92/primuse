import Foundation

public struct LibraryInsightImportedDraft: Equatable, Sendable {
    public let summary: String
    public let tags: [String]
    public let sourceLabel: String
    public let sourceURL: URL?

    public init(summary: String, tags: [String], sourceLabel: String, sourceURL: URL? = nil) {
        self.summary = LibraryInsightEditing.normalizedSummary(summary)
        self.tags = LibraryInsightEditing.normalizedTags(tags)
        self.sourceLabel = sourceLabel
        self.sourceURL = sourceURL
    }
}

public enum LastFmLibraryInsight {
    public static func language(_ identifier: String) -> String {
        let code = identifier.lowercased().split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
        return code.count == 2 && code.utf8.allSatisfy { (97...122).contains($0) } ? code : "en"
    }

    public static func queryItems(for subject: LibraryInsightSubject, languageCode: String) -> [URLQueryItem]? {
        let artist = subject.artistName.trimmingCharacters(in: .whitespacesAndNewlines)
        let album = subject.albumTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artist.isEmpty, !TagCleanupPolicy.isPlaceholder(artist),
              subject.kind != .album || (!album.isEmpty && !TagCleanupPolicy.isPlaceholder(album)) else { return nil }
        var items = [
            URLQueryItem(name: "method", value: subject.kind == .artist ? "artist.getInfo" : "album.getInfo"),
            URLQueryItem(name: "artist", value: artist),
            URLQueryItem(name: "autocorrect", value: "1"),
            URLQueryItem(name: "lang", value: language(languageCode))
        ]
        if subject.kind == .album { items.append(URLQueryItem(name: "album", value: album)) }
        return items
    }

    public static func decode(_ data: Data, for subject: LibraryInsightSubject) throws -> LibraryInsightImportedDraft? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let item = json[subject.kind.rawValue] as? [String: Any] else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Missing Last.fm insight"))
        }
        let wiki = item[subject.kind == .artist ? "bio" : "wiki"] as? [String: Any]
        let summary = [wiki?["content"], wiki?["summary"]]
            .compactMap { $0 as? String }.map(plainText).first { !$0.isEmpty } ?? ""
        // 有标签却没有介绍也算未找到,避免用空正文覆盖已有简介。
        guard !summary.isEmpty else { return nil }
        let tags = (item["tags"] ?? item["toptags"]) as? [String: Any]
        let rawTags = (tags?["tag"] as? [[String: Any]])
            ?? (tags?["tag"] as? [String: Any]).map { [$0] } ?? []
        let sourceURL = sourceURL(item["url"] as? String, subject: subject)
        return LibraryInsightImportedDraft(
            summary: summary, tags: rawTags.compactMap { $0["name"] as? String },
            sourceLabel: "Last.fm", sourceURL: sourceURL
        )
    }

    private static func plainText(_ text: String) -> String {
        let withoutFooter = text.replacingOccurrences(
            of: #"(?is)\s*<a\b[^>]*>\s*Read more on Last\.fm\s*</a>.*$"#,
            with: "", options: .regularExpression
        )
        let paragraphs = withoutFooter.replacingOccurrences(
            of: #"(?i)</p\s*>"#, with: "\n\n", options: .regularExpression
        )
        var plain = LibraryInsightNFO.plainText(fromMarkup: paragraphs)
        if let entities = try? NSRegularExpression(pattern: #"&#(x[0-9a-f]+|[0-9]+);"#, options: .caseInsensitive) {
            for match in entities.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)).reversed() {
                guard let digitsRange = Range(match.range(at: 1), in: plain),
                      let entityRange = Range(match.range, in: plain) else { continue }
                let digits = String(plain[digitsRange])
                let isHex = digits.lowercased().hasPrefix("x")
                guard let value = UInt32(isHex ? String(digits.dropFirst()) : digits, radix: isHex ? 16 : 10),
                      let scalar = UnicodeScalar(value) else { continue }
                plain.replaceSubrange(entityRange, with: String(scalar))
            }
        }
        return LibraryInsightEditing.normalizedSummary(plain)
    }

    private static func sourceURL(_ raw: String?, subject: LibraryInsightSubject) -> URL? {
        if let raw, var components = URLComponents(string: raw),
           ["last.fm", "www.last.fm"].contains(components.host?.lowercased() ?? ""),
           ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
           components.user == nil, components.password == nil, components.port == nil,
           components.path.hasPrefix("/music/") {
            components.scheme = "https"
            components.query = nil
            components.fragment = nil
            return components.url
        }
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))
        let names = subject.kind == .album ? [subject.artistName, subject.albumTitle] : [subject.artistName]
        let path = names.map { $0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }.joined(separator: "/")
        return URL(string: "https://www.last.fm/music/" + path)
    }
}
