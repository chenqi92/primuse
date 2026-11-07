import Foundation

public enum PodcastFeedDiscovery {
    /// 只跟随页面声明的订阅源，不把任意网页链接或音频文件当作 RSS。
    public static func feedURLs(in text: String, baseURL: URL? = nil) -> [URL] {
        let head = String(text.prefix(262_144))
        guard let tags = try? NSRegularExpression(pattern: #"(?is)<(?:[\w-]+:)?link\b[^>]*>"#),
              let attributes = try? NSRegularExpression(pattern: #"([\w:-]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) else { return [] }
        let ns = head as NSString
        var seen = Set<String>()
        return tags.matches(in: head, range: NSRange(location: 0, length: ns.length)).compactMap { tag in
            let body = ns.substring(with: tag.range)
            let bodyNS = body as NSString
            var values: [String: String] = [:]
            for match in attributes.matches(in: body, range: NSRange(location: 0, length: bodyNS.length)) {
                let key = bodyNS.substring(with: match.range(at: 1)).lowercased()
                if let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) {
                    values[key] = bodyNS.substring(with: range).replacingOccurrences(of: "&amp;", with: "&")
                }
            }
            let rel = (values["rel"] ?? "").lowercased().split(whereSeparator: \.isWhitespace)
            let type = (values["type"] ?? "").lowercased().split(separator: ";").first.map(String.init) ?? ""
            guard rel.contains("alternate") || rel.contains("self"),
                  ["application/rss+xml", "application/atom+xml"].contains(type),
                  let href = values["href"],
                  let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let url = PodcastFeedURL.normalized(resolved.absoluteString),
                  seen.insert(PodcastFeedURL.identityKey(for: url)).inserted else { return nil }
            return url
        }
    }
}
