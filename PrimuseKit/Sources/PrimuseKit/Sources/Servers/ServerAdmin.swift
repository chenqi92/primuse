import Foundation

/// 音乐服务器的「服务器管理」:各家服务器(Navidrome、Jellyfin、Emby)的用户与媒体库,
/// 换成同一套数据给界面用。只有管理员账号能用。
public enum ServerAdmin {
    public struct Access: Equatable, Sendable {
        public let userID: String
        public let username: String
        public let isAdmin: Bool
        /// 这家服务器有没有「显示名称」「邮箱」这两项(Jellyfin、Emby 只有用户名)。
        public let editsDisplayName: Bool
        public let editsEmail: Bool

        public init(userID: String, username: String, isAdmin: Bool, editsDisplayName: Bool, editsEmail: Bool) {
            self.userID = userID
            self.username = username
            self.isAdmin = isAdmin
            self.editsDisplayName = editsDisplayName
            self.editsEmail = editsEmail
        }
    }

    public struct Library: Equatable, Sendable, Identifiable, Hashable {
        public let id: String
        public let name: String
        public let songCount: Int?

        public init(id: String, name: String, songCount: Int? = nil) {
            self.id = id
            self.name = name
            self.songCount = songCount
        }
    }

    public struct User: Equatable, Sendable, Identifiable {
        public let id: String
        public let userName: String
        public let displayName: String?
        public let email: String?
        public let isAdmin: Bool
        public let isDisabled: Bool
        public let lastSeenAt: Date?
        /// 能看到的媒体库;nil 表示全部(或这台服务器不分库)。
        public let libraryIDs: [String]?

        public init(
            id: String, userName: String, displayName: String? = nil, email: String? = nil,
            isAdmin: Bool, isDisabled: Bool = false, lastSeenAt: Date? = nil, libraryIDs: [String]? = nil
        ) {
            self.id = id
            self.userName = userName
            self.displayName = displayName
            self.email = email
            self.isAdmin = isAdmin
            self.isDisabled = isDisabled
            self.lastSeenAt = lastSeenAt
            self.libraryIDs = libraryIDs
        }
    }

    /// 新建或修改。`password` 为 nil 时不改密码;`libraryIDs` 为 nil 时不动库权限。
    public struct Draft: Equatable, Sendable {
        public var userName: String
        public var displayName: String
        public var email: String
        public var password: String?
        public var isAdmin: Bool
        public var libraryIDs: [String]?

        public init(
            userName: String, displayName: String = "", email: String = "",
            password: String? = nil, isAdmin: Bool = false, libraryIDs: [String]? = nil
        ) {
            self.userName = userName
            self.displayName = displayName
            self.email = email
            self.password = password
            self.isAdmin = isAdmin
            self.libraryIDs = libraryIDs
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        case unavailable
        case notAdmin
        case authenticationFailed
        case accountMismatch
        case invalidResponse
        case duplicateName
        case rejected(String?)
    }
}

/// Jellyfin、Emby 的 `/Users` 一套接口:解析返回、拼请求体。两家的数据长得一样(Emby 是 Jellyfin 的前身)。
public enum MediaServerUserAdminPayloads {
    public static func users(from data: Data) throws -> [ServerAdmin.User] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ServerAdmin.Failure.invalidResponse
        }
        return array.compactMap(user)
    }

    public static func user(_ json: [String: Any]) -> ServerAdmin.User? {
        guard let id = json["Id"] as? String, !id.isEmpty, let name = json["Name"] as? String else { return nil }
        let policy = json["Policy"] as? [String: Any] ?? [:]
        let allFolders = policy["EnableAllFolders"] as? Bool ?? true
        return ServerAdmin.User(
            id: id,
            userName: name,
            isAdmin: policy["IsAdministrator"] as? Bool ?? false,
            isDisabled: policy["IsDisabled"] as? Bool ?? false,
            lastSeenAt: date(json["LastActivityDate"]) ?? date(json["LastLoginDate"]),
            libraryIDs: allFolders ? nil : (policy["EnabledFolders"] as? [String] ?? [])
        )
    }

    /// 当前登录的这个账号是不是管理员(`GET /Users/{id}` 的返回)。
    public static func isAdministrator(userData: Data) throws -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              let policy = json["Policy"] as? [String: Any] else {
            throw ServerAdmin.Failure.invalidResponse
        }
        return policy["IsAdministrator"] as? Bool ?? false
    }

    /// `GET /Library/MediaFolders` 的返回:`{"Items":[{"Id":…,"Name":…}]}`。
    public static func libraries(from data: Data) throws -> [ServerAdmin.Library] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["Items"] as? [[String: Any]] else {
            throw ServerAdmin.Failure.invalidResponse
        }
        return items.compactMap { item in
            guard let id = item["Id"] as? String, let name = item["Name"] as? String else { return nil }
            return ServerAdmin.Library(id: id, name: name)
        }
    }

    /// 改权限要把整份策略原样发回去,只换这几项;别的字段(下载、转码、登录方式…)不动,否则会被清掉。
    /// `userData` 是 `GET /Users/{id}` 的返回。
    public static func policyUpdate(userData: Data, isAdmin: Bool, libraryIDs: [String]?) throws -> Data {
        guard let json = try? JSONSerialization.jsonObject(with: userData) as? [String: Any],
              var policy = json["Policy"] as? [String: Any] else {
            throw ServerAdmin.Failure.invalidResponse
        }
        policy["IsAdministrator"] = isAdmin
        if isAdmin {
            policy["EnableAllFolders"] = true
        } else if let libraryIDs {
            policy["EnableAllFolders"] = false
            policy["EnabledFolders"] = libraryIDs
        }
        return try JSONSerialization.data(withJSONObject: policy)
    }

    public static func newUserBody(name: String, password: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["Name": name, "Password": password])
    }

    /// 管理员给别人设密码不用旧密码。Emby 还要带上 `Id`。
    public static func passwordBody(userID: String, newPassword: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "Id": userID, "NewPw": newPassword, "ResetPassword": false,
        ])
    }

    /// 服务器拒绝时给的原因;Jellyfin 重名是 `A user with the name 'x' already exists.`。
    public static func failure(status: Int, body: Data) -> ServerAdmin.Failure {
        let text = String(data: body, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch status {
        case 401: return .authenticationFailed
        case 403: return .notAdmin
        case 404, 405, 501: return .unavailable
        default:
            if let text, text.localizedCaseInsensitiveContains("already exists") { return .duplicateName }
            return .rejected(text?.isEmpty == false ? String(text!.prefix(300)) : nil)
        }
    }

    /// .NET 的时间带七位小数:`2026-11-18T09:12:03.1234567Z`。截到毫秒再解析。
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone]
            text.replaceSubrange(dot..<zone, with: "." + fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".") ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
