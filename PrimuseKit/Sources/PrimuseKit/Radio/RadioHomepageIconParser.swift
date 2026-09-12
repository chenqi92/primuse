import Foundation

/// 从电台主页 HTML 里挑出来的一个图标候选。
public struct RadioHomepageIcon: Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// `og:image` / `twitter:image` —— 分享用的大图，通常就是电台台标。
        case openGraph
        /// `apple-touch-icon` —— 180×180 左右，方形，质量普遍不错。
        case appleTouch
        /// Windows 磁贴图。
        case tile
        /// 普通 `rel="icon"` / `shortcut icon`。多半只有 16~32 像素。
        case favicon
    }

    public let urlString: String
    public let kind: Kind
    /// 从 `sizes="180x180"` 解析出的边长；缺省时按种类给一个保守估计。
    public let pixelSize: Int

    public init(urlString: String, kind: Kind, pixelSize: Int) {
        self.urlString = urlString
        self.kind = kind
        self.pixelSize = pixelSize
    }
}

/// 主页 HTML → 图标候选列表。纯字符串处理，没有网络访问。
///
/// 调用方只应把响应的前若干 KB 喂进来：图标声明都在 `<head>` 里，
/// 整页 HTML 可能有好几 MB，没必要也不应该全读。
public enum RadioHomepageIconParser {
    /// 小于这个边长的图标不值得当封面 —— 16×16 的 favicon 放大到播放页
    /// 只会是一团马赛克。`favicon.ico` 兜底路径由调用方单独决定。
    public static let minimumUsefulPixelSize = 48

    /// 按可用性排序的候选。同分时大的在前。
    public static func icons(in html: String, baseURL: URL?) -> [RadioHomepageIcon] {
        var icons: [RadioHomepageIcon] = []

        for tag in tags(in: html) {
            let attributes = attributes(in: tag.body)
            switch tag.name {
            case "meta":
                let property = (attributes["property"] ?? attributes["name"] ?? "").lowercased()
                guard let content = attributes["content"] else { continue }
                let kind: RadioHomepageIcon.Kind
                switch property {
                case "og:image", "og:image:url", "og:image:secure_url", "twitter:image",
                     "twitter:image:src":
                    kind = .openGraph
                case "msapplication-tileimage":
                    kind = .tile
                default:
                    continue
                }
                guard let url = RadioLogoURLPolicy.normalized(content, relativeTo: baseURL),
                      RadioLogoURLPolicy.looksLikeBitmap(url) || kind == .openGraph else {
                    continue
                }
                icons.append(RadioHomepageIcon(
                    urlString: url,
                    kind: kind,
                    pixelSize: defaultPixelSize(for: kind)
                ))

            case "link":
                let rel = (attributes["rel"] ?? "").lowercased()
                guard let href = attributes["href"] else { continue }
                let kind: RadioHomepageIcon.Kind
                if rel.contains("apple-touch-icon") {
                    kind = .appleTouch
                } else if rel.split(separator: " ").contains("icon") {
                    kind = .favicon
                } else {
                    continue
                }
                guard let url = RadioLogoURLPolicy.normalized(href, relativeTo: baseURL) else {
                    continue
                }
                icons.append(RadioHomepageIcon(
                    urlString: url,
                    kind: kind,
                    pixelSize: parsedPixelSize(attributes["sizes"])
                        ?? defaultPixelSize(for: kind)
                ))

            default:
                continue
            }
        }

        return deduplicated(icons).sorted { lhs, rhs in
            if lhs.kind != rhs.kind {
                return priority(lhs.kind) < priority(rhs.kind)
            }
            if lhs.pixelSize != rhs.pixelSize { return lhs.pixelSize > rhs.pixelSize }
            return lhs.urlString < rhs.urlString
        }
    }

    /// 主页上一个图标都没声明时的最后兜底。`/favicon.ico` 是事实标准路径，
    /// 但它通常很小，所以只在没有别的候选时才用。
    public static func fallbackFaviconURL(for baseURL: URL?) -> String? {
        guard let baseURL else { return nil }
        return RadioLogoURLPolicy.normalized("/favicon.ico", relativeTo: baseURL)
    }

    private static func priority(_ kind: RadioHomepageIcon.Kind) -> Int {
        switch kind {
        case .openGraph: return 0
        case .appleTouch: return 1
        case .tile: return 2
        case .favicon: return 3
        }
    }

    private static func defaultPixelSize(for kind: RadioHomepageIcon.Kind) -> Int {
        switch kind {
        case .openGraph: return 512
        case .appleTouch: return 180
        case .tile: return 144
        case .favicon: return 32
        }
    }

    private static func parsedPixelSize(_ raw: String?) -> Int? {
        guard let raw = raw?.lowercased() else { return nil }
        // `sizes="16x16 32x32"` 是合法写法，取最大的那个。
        let sizes = raw.split(whereSeparator: { $0 == " " || $0 == "," })
            .compactMap { token -> Int? in
                let parts = token.split(separator: "x")
                guard let first = parts.first, let value = Int(first) else { return nil }
                return value
            }
        return sizes.max()
    }

    private static func deduplicated(_ icons: [RadioHomepageIcon]) -> [RadioHomepageIcon] {
        var seen = Set<String>()
        var result: [RadioHomepageIcon] = []
        for icon in icons where seen.insert(icon.urlString).inserted {
            result.append(icon)
        }
        return result
    }

    // MARK: - 极简标签扫描

    private struct Tag {
        let name: String
        let body: String
    }

    /// 只抓 `<link>` 和 `<meta>`。不做 HTML 解析 —— 属性顺序、引号种类、
    /// 大小写都按最宽松处理，抓不到就当没有，绝不因为页面写得野就崩。
    private static func tags(in html: String) -> [Tag] {
        var tags: [Tag] = []
        var index = html.startIndex

        while let open = html.range(of: "<", range: index..<html.endIndex) {
            guard let close = html.range(of: ">", range: open.upperBound..<html.endIndex) else {
                break
            }
            let inner = html[open.upperBound..<close.lowerBound]
            index = close.upperBound

            let name = inner.prefix { !$0.isWhitespace && $0 != "/" }.lowercased()
            guard name == "link" || name == "meta" else { continue }
            tags.append(Tag(name: name, body: String(inner.dropFirst(name.count))))
        }

        return tags
    }

    private static func attributes(in body: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = body.startIndex

        while index < body.endIndex {
            // 跳过分隔空白。
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
            guard index < body.endIndex else { break }

            let nameStart = index
            while index < body.endIndex,
                  !body[index].isWhitespace,
                  body[index] != "=" {
                index = body.index(after: index)
            }
            let name = body[nameStart..<index]
                .trimmingCharacters(in: .whitespaces)
                .lowercased()
            guard index < body.endIndex, body[index] == "=" else {
                if !name.isEmpty, result[name] == nil { result[name] = "" }
                continue
            }
            index = body.index(after: index)
            while index < body.endIndex, body[index].isWhitespace {
                index = body.index(after: index)
            }
            guard index < body.endIndex else { break }

            var value = ""
            if body[index] == "\"" || body[index] == "'" {
                let quote = body[index]
                index = body.index(after: index)
                let valueStart = index
                while index < body.endIndex, body[index] != quote {
                    index = body.index(after: index)
                }
                value = String(body[valueStart..<index])
                if index < body.endIndex { index = body.index(after: index) }
            } else {
                let valueStart = index
                while index < body.endIndex, !body[index].isWhitespace {
                    index = body.index(after: index)
                }
                value = String(body[valueStart..<index])
            }

            if !name.isEmpty, result[name] == nil {
                result[name] = value.decodingBasicHTMLEntities()
            }
        }

        return result
    }
}

private extension String {
    /// HTML 属性里最常见的几个实体。`&amp;` 出现在带查询参数的图片地址里很普遍，
    /// 不还原的话地址直接就是坏的。
    func decodingBasicHTMLEntities() -> String {
        guard contains("&") else { return self }
        var result = self
        for (entity, replacement) in [
            ("&amp;", "&"), ("&#38;", "&"), ("&#x26;", "&"),
            ("&quot;", "\""), ("&#34;", "\""),
            ("&apos;", "'"), ("&#39;", "'"),
            ("&lt;", "<"), ("&gt;", ">"),
        ] {
            result = result.replacingOccurrences(
                of: entity,
                with: replacement,
                options: .caseInsensitive
            )
        }
        return result
    }
}
