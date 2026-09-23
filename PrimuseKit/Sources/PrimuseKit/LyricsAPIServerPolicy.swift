import Foundation

/// 用户自填的歌词 API 服务器（音流「自定义 API」/ LrcApi 事实标准）。
/// 地址原样保存（只去掉首尾空白），不做 https 升级也不限制主机。
public struct LyricsAPIServer: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var address: String
    public var authorization: String?

    public init(id: String = UUID().uuidString, address: String, authorization: String? = nil) {
        self.id = id
        self.address = address
        self.authorization = authorization
    }
}

/// 歌词 API 服务器的纯策略：地址校验、请求 URL 拼装、响应分类。
public enum LyricsAPIServerPolicy {
    /// 响应体上限，超过视为不是歌词。
    public static let maximumBodyBytes = 2 * 1024 * 1024

    /// 用户说了「地址不设限制」：只要求能解析、scheme 为 http/https、有 host；端口、路径、
    /// 已有 query、公网 http 一律允许，不做 https 升级，不做局域网判断。返回 trim 后的地址，
    /// 不满足返回 nil。
    public static func normalizedAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        return trimmed
    }

    /// 在用户地址上追加 title / artist / album / duration 查询参数（artist/album 为 nil 或空白时不带；
    /// duration 只在有限且 > 0 时带，取整秒）。用户地址里已有的 query 项保留在前面。
    public static func requestURL(
        address: String,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?
    ) -> URL? {
        guard let normalized = normalizedAddress(address),
              var components = URLComponents(string: normalized)
        else { return nil }

        var items: [URLQueryItem] = []
        items.append(URLQueryItem(name: "title", value: title))
        if let artist = nonBlank(artist) {
            items.append(URLQueryItem(name: "artist", value: artist))
        }
        if let album = nonBlank(album) {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if let duration, duration.isFinite, duration >= 1, duration < 1_000_000_000 {
            items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded(.down)))))
        }

        var appended = URLComponents()
        appended.queryItems = items
        // URLQueryItem 不会编码 `+`，而多数服务端把 `+` 当空格；只对追加的参数补编码，
        // 用户地址里原有的 query 原样保留在前面。
        let appendedQuery = (appended.percentEncodedQuery ?? "")
            .replacingOccurrences(of: "+", with: "%2B")
        if let existing = components.percentEncodedQuery, !existing.isEmpty {
            components.percentEncodedQuery = existing + "&" + appendedQuery
        } else {
            components.percentEncodedQuery = appendedQuery
        }
        return components.url
    }

    public enum ResponseClassification: Equatable, Sendable {
        /// 该服务明确没有：404、204、空体、HTML 页面、JSON 里没有歌词、只有一行的短文本
        case notFound
        /// 至少一个非空
        case lyrics(lrc: String?, plain: String?)
        /// 401/403/429/5xx 等其它状态码
        case failed(statusCode: Int)
    }

    public static func classifyResponse(
        statusCode: Int,
        contentType: String?,
        body: Data
    ) -> ResponseClassification {
        if statusCode == 404 || statusCode == 204 { return .notFound }
        guard statusCode == 200 else { return .failed(statusCode: statusCode) }
        guard body.count <= maximumBodyBytes else { return .notFound }
        guard let text = String(data: body, encoding: .utf8) else { return .notFound }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let declaresJSON = contentType?.lowercased().contains("json") == true
        if declaresJSON || trimmed.hasPrefix("[") || trimmed.hasPrefix("{") {
            if let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed]) {
                return classifyJSON(json)
            }
        }
        return classifyText(text)
    }

    // MARK: - Private

    private static let lyricKeys = ["lyrics", "lrc", "syncedLyrics"]

    private static func classifyJSON(_ json: Any) -> ResponseClassification {
        if let array = json as? [Any] {
            for element in array {
                guard let object = element as? [String: Any] else { continue }
                for key in lyricKeys {
                    if let value = nonBlankString(object[key]) {
                        return classifyLyricString(value)
                    }
                }
            }
            return .notFound
        }
        if let object = json as? [String: Any] {
            for key in lyricKeys {
                if let value = nonBlankString(object[key]) {
                    return classifyLyricString(value)
                }
            }
            if let plain = nonBlankString(object["plainLyrics"]) {
                return .lyrics(lrc: nil, plain: normalizedNewlines(plain).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return .notFound
        }
        return .notFound
    }

    private static func classifyLyricString(_ value: String) -> ResponseClassification {
        let text = normalizedNewlines(value).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notFound }
        return containsTimestamp(text) ? .lyrics(lrc: text, plain: nil) : .lyrics(lrc: nil, plain: text)
    }

    private static func classifyText(_ raw: String) -> ResponseClassification {
        let text = normalizedNewlines(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .notFound }
        if text.hasPrefix("<") {
            let lowered = text.lowercased()
            if lowered.contains("<html") || lowered.contains("<!doctype") { return .notFound }
        }
        if containsTimestamp(text) { return .lyrics(lrc: text, plain: nil) }
        let nonEmptyLines = text.split(separator: "\n").filter {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard nonEmptyLines.count > 1 else { return .notFound }
        return .lyrics(lrc: nil, plain: text)
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func containsTimestamp(_ text: String) -> Bool {
        text.range(of: #"\[\d{1,2}:\d{2}(?:[.:]\d{1,3})?\]"#, options: .regularExpression) != nil
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonBlankString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : string
    }
}
