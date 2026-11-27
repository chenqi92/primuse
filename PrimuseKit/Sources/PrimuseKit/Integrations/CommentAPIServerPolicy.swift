import Foundation

/// 用户自行配置的评论 API 服务（纯客户端协议，不内置任何第三方服务地址）。
/// 地址原样保存（仅去除首尾空白），不做 https 升级也不限制主机；
/// `authorization` 仅在内存草稿或从钥匙串补回时存在，落盘与同步前一律剥离。
public struct CommentAPIServer: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var address: String
    public var authorization: String?
    public var isEnabled: Bool

    public init(
        id: String = UUID().uuidString,
        name: String = "",
        address: String,
        authorization: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.authorization = authorization
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, address, authorization, isEnabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        address = try container.decode(String.self, forKey: .address)
        authorization = try container.decodeIfPresent(String.self, forKey: .authorization)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }

    /// 展示名：用户填写了名称用名称，否则退回主机名，再退回完整地址。
    public var displayTitle: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return CommentAPIServerPolicy.displayHost(for: address) ?? address
    }
}

/// 评论排序方式。
public enum SongCommentSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case hot
    case latest

    public var id: String { rawValue }
}

/// 评论楼中楼回复条目。
public struct SongCommentReply: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var authorName: String
    public var authorID: String?
    public var avatarURL: String?
    public var content: String
    public var timestamp: Date?
    public var timeText: String?
    public var likedCount: Int?
    public var replyToAuthorName: String?

    public init(
        id: String,
        authorName: String,
        authorID: String? = nil,
        avatarURL: String? = nil,
        content: String,
        timestamp: Date? = nil,
        timeText: String? = nil,
        likedCount: Int? = nil,
        replyToAuthorName: String? = nil
    ) {
        self.id = id
        self.authorName = authorName
        self.authorID = authorID
        self.avatarURL = avatarURL
        self.content = content
        self.timestamp = timestamp
        self.timeText = timeText
        self.likedCount = likedCount
        self.replyToAuthorName = replyToAuthorName
    }

    public var authorBlockKey: String {
        CommentAPIServerPolicy.authorBlockKey(authorID: authorID, authorName: authorName)
    }
}

/// 单条歌曲评论。
public struct SongCommentItem: Codable, Sendable, Identifiable, Hashable {
    public var id: String
    public var authorName: String
    public var authorID: String?
    public var avatarURL: String?
    public var content: String
    public var timestamp: Date?
    public var timeText: String?
    public var likedCount: Int?
    public var location: String?
    public var badge: String?
    public var isPinned: Bool
    public var isHot: Bool
    public var replies: [SongCommentReply]

    public init(
        id: String,
        authorName: String,
        authorID: String? = nil,
        avatarURL: String? = nil,
        content: String,
        timestamp: Date? = nil,
        timeText: String? = nil,
        likedCount: Int? = nil,
        location: String? = nil,
        badge: String? = nil,
        isPinned: Bool = false,
        isHot: Bool = false,
        replies: [SongCommentReply] = []
    ) {
        self.id = id
        self.authorName = authorName
        self.authorID = authorID
        self.avatarURL = avatarURL
        self.content = content
        self.timestamp = timestamp
        self.timeText = timeText
        self.likedCount = likedCount
        self.location = location
        self.badge = badge
        self.isPinned = isPinned
        self.isHot = isHot
        self.replies = replies
    }

    public var authorBlockKey: String {
        CommentAPIServerPolicy.authorBlockKey(authorID: authorID, authorName: authorName)
    }
}

/// 单页评论响应结果。
public struct SongCommentsPage: Equatable, Sendable {
    public var total: Int?
    public var hasMore: Bool
    public var hotComments: [SongCommentItem]
    public var comments: [SongCommentItem]
    public var nextCursor: String?

    public init(
        total: Int? = nil,
        hasMore: Bool = false,
        hotComments: [SongCommentItem] = [],
        comments: [SongCommentItem] = [],
        nextCursor: String? = nil
    ) {
        self.total = total
        self.hasMore = hasMore
        self.hotComments = hotComments
        self.comments = comments
        self.nextCursor = nextCursor
    }

    public var isEmpty: Bool {
        hotComments.isEmpty && comments.isEmpty
    }

    public var visibleCount: Int {
        hotComments.count + comments.count
    }
}

/// 纯本地内容屏蔽与隐藏列表（有界容量，FIFO 淘汰，遵循内存与存储纪律）。
public struct SongCommentModeration: Codable, Equatable, Sendable {
    public static let maxHiddenComments = 500
    public static let maxBlockedAuthors = 200

    public var hiddenCommentIDs: [String]
    public var blockedAuthorKeys: [String]
    public var blockedAuthorNames: [String: String]

    public init(
        hiddenCommentIDs: [String] = [],
        blockedAuthorKeys: [String] = [],
        blockedAuthorNames: [String: String] = [:]
    ) {
        self.hiddenCommentIDs = Array(hiddenCommentIDs.suffix(Self.maxHiddenComments))
        self.blockedAuthorKeys = Array(blockedAuthorKeys.suffix(Self.maxBlockedAuthors))
        let allowed = Set(self.blockedAuthorKeys)
        self.blockedAuthorNames = blockedAuthorNames.filter { allowed.contains($0.key) }
    }

    public var isEmpty: Bool {
        hiddenCommentIDs.isEmpty && blockedAuthorKeys.isEmpty
    }

    public mutating func hideComment(id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        hiddenCommentIDs.removeAll { $0 == trimmed }
        hiddenCommentIDs.append(trimmed)
        if hiddenCommentIDs.count > Self.maxHiddenComments {
            hiddenCommentIDs.removeFirst(hiddenCommentIDs.count - Self.maxHiddenComments)
        }
    }

    public mutating func blockAuthor(key: String, displayName: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        blockedAuthorKeys.removeAll { $0 == trimmed }
        blockedAuthorKeys.append(trimmed)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        blockedAuthorNames[trimmed] = name.isEmpty ? trimmed : name
        if blockedAuthorKeys.count > Self.maxBlockedAuthors {
            let overflow = blockedAuthorKeys.count - Self.maxBlockedAuthors
            let removed = blockedAuthorKeys.prefix(overflow)
            blockedAuthorKeys.removeFirst(overflow)
            for evicted in removed {
                blockedAuthorNames.removeValue(forKey: evicted)
            }
        }
    }

    public mutating func unblockAuthor(key: String) {
        blockedAuthorKeys.removeAll { $0 == key }
        blockedAuthorNames.removeValue(forKey: key)
    }

    public mutating func clearHiddenComments() {
        hiddenCommentIDs.removeAll()
    }

    public mutating func clearAll() {
        hiddenCommentIDs.removeAll()
        blockedAuthorKeys.removeAll()
        blockedAuthorNames.removeAll()
    }

    public func isHidden(commentID: String) -> Bool {
        hiddenCommentIDs.contains(commentID)
    }

    public func isBlocked(authorKey: String) -> Bool {
        blockedAuthorKeys.contains(authorKey)
    }

    /// 过滤已隐藏的评论与已屏蔽作者（含楼中楼回复）。
    public func filter(_ items: [SongCommentItem]) -> [SongCommentItem] {
        guard !isEmpty else { return items }
        let hidden = Set(hiddenCommentIDs)
        let blocked = Set(blockedAuthorKeys)
        return items.compactMap { item in
            guard !hidden.contains(item.id), !blocked.contains(item.authorBlockKey) else {
                return nil
            }
            guard !item.replies.isEmpty else { return item }
            var copy = item
            copy.replies = item.replies.filter { reply in
                !hidden.contains(reply.id) && !blocked.contains(reply.authorBlockKey)
            }
            return copy
        }
    }

    public func filter(_ page: SongCommentsPage) -> SongCommentsPage {
        guard !isEmpty else { return page }
        return SongCommentsPage(
            total: page.total,
            hasMore: page.hasMore,
            hotComments: filter(page.hotComments),
            comments: filter(page.comments),
            nextCursor: page.nextCursor
        )
    }
}

/// 评论 API 服务的纯策略：地址校验、URL 模板/参数拼装、通用 JSON 响应解析。
public enum CommentAPIServerPolicy {
    public static let maximumBodyBytes = 2 * 1024 * 1024
    public static let maximumItemsPerPage = 200
    public static let maximumRepliesPerItem = 20
    public static let defaultPageSize = 20

    private static let placeholderTokens = [
        "{{title}}", "{{artist}}", "{{album}}", "{{duration}}",
        "{{sort}}", "{{page}}", "{{limit}}", "{{cursor}}",
    ]

    /// 校验并规范化地址：允许 http/https 及端口、路径、已有参数与 `{{...}}` 模板占位符（禁止出现在 scheme/host 中）。
    public static func normalizedAddress(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let schemeSeparator = trimmed.range(of: "://") else { return nil }
        let schemePart = trimmed[..<schemeSeparator.lowerBound]
        guard !schemePart.contains("{"), !schemePart.contains("}") else { return nil }
        let afterScheme = trimmed[schemeSeparator.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "#" }) ?? afterScheme.endIndex
        let authority = afterScheme[..<authorityEnd]
        guard !authority.isEmpty, !authority.contains("{"), !authority.contains("}") else { return nil }

        // URLComponents 不接受原始花括号；验证时用安全占位文本替换路径/查询中的占位符后再解析。
        let probe = placeholderTokens.reduce(trimmed) { result, token in
            result.replacingOccurrences(of: token, with: "placeholder")
        }
        guard let components = URLComponents(string: probe),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host,
              !host.isEmpty
        else { return nil }
        return trimmed
    }

    /// 安全展示主机（含端口），不含路径、查询参数与凭据。
    public static func displayHost(for address: String) -> String? {
        guard let normalized = normalizedAddress(address) else { return nil }
        let probe = placeholderTokens.reduce(normalized) { result, token in
            result.replacingOccurrences(of: token, with: "placeholder")
        }
        guard let components = URLComponents(string: probe), let host = components.host, !host.isEmpty else {
            return nil
        }
        if let port = components.port { return "\(host):\(port)" }
        return host
    }

    public static func authorBlockKey(authorID: String?, authorName: String) -> String {
        if let authorID = nonBlank(authorID) {
            return "id:\(authorID)"
        }
        let normalizedName = authorName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "name:\(normalizedName.isEmpty ? "anonymous" : normalizedName)"
    }

    /// 拼装评论请求 URL：
    /// - 若地址包含 `{{...}}` 占位符，按模板替换（并进行严格 URL 参数编码）；
    /// - 否则在原有查询参数后追加标准参数 `title` / `artist` / `album` / `duration` / `sort` / `page` / `limit` / `cursor`。
    public static func requestURL(
        address: String,
        title: String,
        artist: String?,
        album: String?,
        duration: TimeInterval?,
        sort: SongCommentSort = .hot,
        page: Int = 1,
        limit: Int = defaultPageSize,
        cursor: String? = nil
    ) -> URL? {
        guard let normalized = normalizedAddress(address) else { return nil }
        let safePage = max(1, page)
        let safeLimit = min(max(1, limit), maximumItemsPerPage)
        let durationText: String? = {
            guard let duration, duration.isFinite, duration >= 1, duration < 1_000_000_000 else { return nil }
            return String(Int(duration.rounded(.down)))
        }()

        if placeholderTokens.contains(where: normalized.contains) {
            let replacements: [String: String] = [
                "{{title}}": percentEncodeQueryValue(title),
                "{{artist}}": percentEncodeQueryValue(nonBlank(artist) ?? ""),
                "{{album}}": percentEncodeQueryValue(nonBlank(album) ?? ""),
                "{{duration}}": percentEncodeQueryValue(durationText ?? ""),
                "{{sort}}": percentEncodeQueryValue(sort.rawValue),
                "{{page}}": String(safePage),
                "{{limit}}": String(safeLimit),
                "{{cursor}}": percentEncodeQueryValue(nonBlank(cursor) ?? ""),
            ]
            var expanded = normalized
            for (token, value) in replacements {
                expanded = expanded.replacingOccurrences(of: token, with: value)
            }
            return URL(string: expanded)
        }

        guard var components = URLComponents(string: normalized) else { return nil }
        var items: [URLQueryItem] = [
            URLQueryItem(name: "title", value: title),
        ]
        if let artist = nonBlank(artist) {
            items.append(URLQueryItem(name: "artist", value: artist))
        }
        if let album = nonBlank(album) {
            items.append(URLQueryItem(name: "album", value: album))
        }
        if let durationText {
            items.append(URLQueryItem(name: "duration", value: durationText))
        }
        items.append(URLQueryItem(name: "sort", value: sort.rawValue))
        items.append(URLQueryItem(name: "page", value: String(safePage)))
        items.append(URLQueryItem(name: "limit", value: String(safeLimit)))
        if let cursor = nonBlank(cursor) {
            items.append(URLQueryItem(name: "cursor", value: cursor))
        }

        var appended = URLComponents()
        appended.queryItems = items
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
        case comments(SongCommentsPage)
        case empty
        case failed(statusCode: Int)
        case invalidFormat
    }

    /// 分类并解析通用 JSON 评论响应。拒绝 HTML 或超过上限的响应体。
    public static func classifyResponse(
        statusCode: Int,
        contentType: String?,
        body: Data
    ) -> ResponseClassification {
        if statusCode == 404 || statusCode == 204 { return .empty }
        guard statusCode == 200 else { return .failed(statusCode: statusCode) }
        guard body.count <= maximumBodyBytes else { return .invalidFormat }
        guard !body.isEmpty else { return .empty }
        guard let decodedText = String(data: body, encoding: .utf8) else { return .invalidFormat }
        let cleaned = decodedText.hasPrefix("\u{FEFF}") ? String(decodedText.dropFirst()) : decodedText
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        if trimmed.hasPrefix("<") {
            let lowered = trimmed.lowercased()
            if lowered.contains("<html") || lowered.contains("<!doctype") {
                return .invalidFormat
            }
        }
        guard trimmed.hasPrefix("{") || trimmed.hasPrefix("["),
              let json = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])
        else { return .invalidFormat }

        guard let page = parseJSON(json) else { return .invalidFormat }
        return page.isEmpty ? .empty : .comments(page)
    }

    /// 将点赞数格式化为紧凑展示文案（按语言环境使用系统紧凑格式）。
    public static func compactLikeCount(_ count: Int, locale: Locale = .current) -> String {
        guard count > 0 else { return "" }
        return count.formatted(.number.notation(.compactName).locale(locale))
    }

    // MARK: - Private JSON Parsing

    private static let queryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?+#/%")
        return set
    }()

    private static func percentEncodeQueryValue(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? ""
    }

    private static func parseJSON(_ json: Any) -> SongCommentsPage? {
        if let array = json as? [Any] {
            let items = parseItems(array, markHot: false, prefix: "c")
            return SongCommentsPage(total: items.count, hasMore: false, hotComments: [], comments: items)
        }
        guard let root = json as? [String: Any] else { return nil }
        let payload = unwrapContainer(root)
        if let array = payload as? [Any] {
            let items = parseItems(array, markHot: false, prefix: "c")
            let total = intValue(root["total"] ?? root["totalCount"] ?? root["count"]) ?? items.count
            let hasMore = boolValue(root["hasMore"] ?? root["more"] ?? root["has_more"]) ?? false
            let nextCursor = nonBlankString(root["nextCursor"] ?? root["cursor"])
            return SongCommentsPage(total: total, hasMore: hasMore, hotComments: [], comments: items, nextCursor: nextCursor)
        }
        guard let object = payload as? [String: Any] else { return nil }

        let hotArray = firstArray(in: object, keys: ["hotComments", "hot_comments", "topComments", "top_comments", "featured"])
        let mainArray = firstArray(in: object, keys: ["comments", "items", "list", "records", "data"])
        guard hotArray != nil || mainArray != nil else {
            // 合法的空结果对象（例如 { "total": 0 }）视为无评论而非格式错误。
            if object["total"] != nil || object["totalCount"] != nil || object["count"] != nil {
                return SongCommentsPage(total: 0, hasMore: false, hotComments: [], comments: [])
            }
            return nil
        }

        let hotItems = parseItems(hotArray ?? [], markHot: true, prefix: "hot")
        let regularItems = parseItems(mainArray ?? [], markHot: false, prefix: "c")
        let total = intValue(
            object["total"] ?? object["totalCount"] ?? object["count"]
                ?? root["total"] ?? root["totalCount"] ?? root["count"]
        )
        let hasMore = boolValue(
            object["hasMore"] ?? object["more"] ?? object["has_more"]
                ?? root["hasMore"] ?? root["more"] ?? root["has_more"]
        ) ?? false
        let nextCursor = nonBlankString(
            object["nextCursor"] ?? object["cursor"] ?? root["nextCursor"] ?? root["cursor"]
        )

        return SongCommentsPage(
            total: total,
            hasMore: hasMore,
            hotComments: hotItems,
            comments: regularItems,
            nextCursor: nextCursor
        )
    }

    private static func unwrapContainer(_ root: [String: Any]) -> Any {
        let directKeys = ["hotComments", "hot_comments", "topComments", "top_comments", "featured", "comments", "items", "list", "records"]
        if directKeys.contains(where: { root[$0] != nil }) {
            return root
        }
        if let data = root["data"] {
            if let dict = data as? [String: Any], directKeys.contains(where: { dict[$0] != nil }) || dict["total"] != nil || dict["count"] != nil {
                return dict
            }
            if data is [Any] { return data }
        }
        if let result = root["result"] {
            if let dict = result as? [String: Any], directKeys.contains(where: { dict[$0] != nil }) || dict["total"] != nil || dict["count"] != nil {
                return dict
            }
            if result is [Any] { return result }
        }
        return root
    }

    private static func firstArray(in object: [String: Any], keys: [String]) -> [Any]? {
        for key in keys {
            if let array = object[key] as? [Any] {
                return array
            }
        }
        return nil
    }

    private static func parseItems(_ raw: [Any], markHot: Bool, prefix: String) -> [SongCommentItem] {
        var seen = Set<String>()
        var result: [SongCommentItem] = []
        result.reserveCapacity(min(raw.count, maximumItemsPerPage))

        for (index, element) in raw.enumerated() {
            guard result.count < maximumItemsPerPage,
                  let dict = element as? [String: Any],
                  let item = parseItem(dict, index: index, markHot: markHot, prefix: prefix)
            else { continue }
            guard seen.insert(item.id).inserted else { continue }
            result.append(item)
        }
        return result
    }

    private static func parseItem(
        _ dict: [String: Any],
        index: Int,
        markHot: Bool,
        prefix: String
    ) -> SongCommentItem? {
        guard let rawContent = nonBlankString(dict["content"] ?? dict["text"] ?? dict["body"] ?? dict["message"]) else {
            return nil
        }
        let content = normalizedNewlines(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }

        let user = (dict["user"] ?? dict["authorInfo"] ?? dict["member"]) as? [String: Any]
        let authorName = nonBlankString(
            user?["nickname"] ?? user?["name"] ?? user?["username"]
                ?? dict["author"] ?? dict["nickname"] ?? dict["username"] ?? dict["userName"]
        ) ?? "Anonymous"
        let authorID = stringID(
            user?["id"] ?? user?["userId"] ?? user?["uid"]
                ?? dict["authorId"] ?? dict["authorID"] ?? dict["userId"] ?? dict["uid"]
        )
        let avatarURL = validHTTPURLString(
            user?["avatarUrl"] ?? user?["avatar"] ?? user?["avatar_url"] ?? user?["picUrl"]
                ?? dict["avatarUrl"] ?? dict["avatar"] ?? dict["avatar_url"]
        )
        let id = stringID(dict["id"] ?? dict["commentId"] ?? dict["comment_id"] ?? dict["cid"])
            ?? fallbackCommentID(prefix: prefix, author: authorName, content: content, index: index)
        let timestamp = parseTimestamp(dict["timestamp"] ?? dict["time"] ?? dict["createdAt"] ?? dict["created_at"] ?? dict["date"])
        let timeText = nonBlankString(dict["timeText"] ?? dict["timeStr"] ?? dict["time_str"] ?? dict["dateText"])
        let likedCount = intValue(dict["likes"] ?? dict["likedCount"] ?? dict["likeCount"] ?? dict["like_count"] ?? dict["upvotes"])
        let ipObject = dict["ipLocation"] as? [String: Any]
        let location = nonBlankString(
            ipObject?["location"] ?? dict["location"] ?? dict["ipLocation"] ?? dict["region"]
        )
        let badge = nonBlankString(dict["badge"] ?? dict["tag"] ?? dict["label"])
        let isPinned = boolValue(dict["isPinned"] ?? dict["pinned"] ?? dict["top"]) ?? false
        let isHot = markHot || (boolValue(dict["isHot"] ?? dict["hot"]) ?? false)
        let replies = parseReplies(
            dict["replies"] ?? dict["beReplied"] ?? dict["children"] ?? dict["subComments"],
            parentID: id
        )

        return SongCommentItem(
            id: id,
            authorName: authorName,
            authorID: authorID,
            avatarURL: avatarURL,
            content: content,
            timestamp: timestamp,
            timeText: timeText,
            likedCount: likedCount,
            location: location,
            badge: badge,
            isPinned: isPinned,
            isHot: isHot,
            replies: replies
        )
    }

    private static func parseReplies(_ raw: Any?, parentID: String) -> [SongCommentReply] {
        guard let array = raw as? [Any], !array.isEmpty else { return [] }
        var seen = Set<String>()
        var replies: [SongCommentReply] = []
        for (index, element) in array.prefix(maximumRepliesPerItem).enumerated() {
            guard let dict = element as? [String: Any],
                  let rawContent = nonBlankString(dict["content"] ?? dict["text"] ?? dict["body"])
            else { continue }
            let content = normalizedNewlines(rawContent).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            let user = (dict["user"] ?? dict["authorInfo"]) as? [String: Any]
            let authorName = nonBlankString(
                user?["nickname"] ?? user?["name"] ?? dict["author"] ?? dict["nickname"] ?? dict["username"]
            ) ?? "Anonymous"
            let authorID = stringID(
                user?["id"] ?? user?["userId"] ?? dict["authorId"] ?? dict["userId"]
            )
            let avatarURL = validHTTPURLString(
                user?["avatarUrl"] ?? user?["avatar"] ?? dict["avatarUrl"] ?? dict["avatar"]
            )
            let id = stringID(
                dict["id"] ?? dict["commentId"] ?? dict["beRepliedCommentId"] ?? dict["replyId"]
            ) ?? "\(parentID)#r\(index)"
            guard seen.insert(id).inserted else { continue }
            let replyTo = nonBlankString(dict["replyTo"] ?? dict["replyToAuthor"] ?? dict["reply_to"])
            replies.append(SongCommentReply(
                id: id,
                authorName: authorName,
                authorID: authorID,
                avatarURL: avatarURL,
                content: content,
                timestamp: parseTimestamp(dict["timestamp"] ?? dict["time"] ?? dict["createdAt"]),
                timeText: nonBlankString(dict["timeText"] ?? dict["timeStr"]),
                likedCount: intValue(dict["likes"] ?? dict["likedCount"] ?? dict["likeCount"]),
                replyToAuthorName: replyTo
            ))
        }
        return replies
    }

    private static func fallbackCommentID(prefix: String, author: String, content: String, index: Int) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in "\(author)|\(content)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return "\(prefix)-\(index)-\(String(hash, radix: 16))"
    }

    private static func parseTimestamp(_ value: Any?) -> Date? {
        if let number = doubleValue(value), number > 0 {
            // 毫秒级时间戳（>= 1e11）转秒；秒级（>= 1e8）直接用。
            if number >= 100_000_000_000 {
                return Date(timeIntervalSince1970: number / 1000.0)
            }
            if number >= 100_000_000 {
                return Date(timeIntervalSince1970: number)
            }
            return nil
        }
        guard let string = nonBlankString(value) else { return nil }
        if let numeric = Double(string) {
            return parseTimestamp(numeric)
        }
        let isoFraction = ISO8601DateFormatter()
        isoFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFraction.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }

    private static func validHTTPURLString(_ value: Any?) -> String? {
        guard let string = nonBlankString(value),
              let components = URLComponents(string: string),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host, !host.isEmpty
        else { return nil }
        return string
    }

    private static func normalizedNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func nonBlank(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func nonBlankString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func stringID(_ value: Any?) -> String? {
        if let string = nonBlankString(value) { return string }
        if let number = value as? NSNumber {
            // 过滤 Bool（Objective-C NSNumber 把 true/false 也当数字）。
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            return number.stringValue
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            guard double.isFinite, double >= 0, double < Double(Int.max) else { return nil }
            return Int(double.rounded(.towardZero))
        }
        if let string = nonBlankString(value), let int = Int(string), int >= 0 {
            return int
        }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let double = number.doubleValue
            return double.isFinite ? double : nil
        }
        return nil
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue
        }
        if let string = nonBlankString(value)?.lowercased() {
            if string == "true" || string == "1" { return true }
            if string == "false" || string == "0" { return false }
        }
        return nil
    }
}
