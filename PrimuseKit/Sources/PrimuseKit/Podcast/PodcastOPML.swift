import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// 播客订阅的 OPML 导入导出,和其他播客 App 互相搬家用。
public enum PodcastOPML {
    public struct Entry: Hashable, Sendable {
        public var title: String?
        public var feedURL: URL

        public init(title: String?, feedURL: URL) {
            self.title = title
            self.feedURL = feedURL
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case notOPML
    }

    /// 读出全部 `xmlUrl`(嵌套分组也读),同一个地址只留一次。
    public static func parse(_ data: Data) throws -> [Entry] {
        let delegate = OPMLDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        guard delegate.sawOPML || !delegate.entries.isEmpty else { throw Failure.notOPML }
        var seen = Set<String>()
        return delegate.entries.filter { seen.insert(PodcastFeedURL.identityKey(for: $0.feedURL)).inserted }
    }

    public static func export(_ shows: [PodcastShow], title: String = "Primuse Podcasts", now: Date = Date()) -> Data {
        let dateText = ISO8601DateFormatter().string(from: now)
        var lines = [
            #"<?xml version="1.0" encoding="UTF-8"?>"#,
            #"<opml version="2.0">"#,
            "  <head>",
            "    <title>\(escape(title))</title>",
            "    <dateCreated>\(dateText)</dateCreated>",
            "  </head>",
            "  <body>",
        ]
        for show in shows {
            var attributes = [
                #"type="rss""#,
                #"text="\#(escape(show.title))""#,
                #"title="\#(escape(show.title))""#,
                #"xmlUrl="\#(escape(show.feedURL.absoluteString))""#,
            ]
            if let website = show.websiteURL {
                attributes.append(#"htmlUrl="\#(escape(website.absoluteString))""#)
            }
            lines.append("    <outline " + attributes.joined(separator: " ") + "/>")
        }
        lines.append(contentsOf: ["  </body>", "</opml>", ""])
        return Data(lines.joined(separator: "\n").utf8)
    }

    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private final class OPMLDelegate: NSObject, XMLParserDelegate {
        var entries: [Entry] = []
        var sawOPML = false

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            switch elementName.lowercased() {
            case "opml":
                sawOPML = true
            case "outline":
                let lowered = Dictionary(attributes.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
                guard let raw = lowered["xmlurl"] ?? lowered["url"], let url = PodcastFeedURL.normalized(raw) else { return }
                let title = (lowered["title"] ?? lowered["text"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                entries.append(Entry(title: title?.isEmpty == false ? title : nil, feedURL: url))
            default:
                break
            }
        }
    }
}
