import Foundation

/// Navidrome 网页后台用的那套原生接口(`/auth/login`、`/api/user`、`/api/library`),
/// 给管理员在 Primuse 里管用户(#148)。只在认出是 Navidrome 之后调用;Subsonic 协议里没有建用户的接口。
/// 令牌只放在内存里;请求经调用方传进来的加载器发出,沿用连接器原来的证书与明文 HTTP 规则。
public enum NavidromeAdmin {
    public typealias RequestDataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public struct Session: Sendable, Equatable {
        public let userID: String
        public let username: String
        public let isAdmin: Bool
        /// 每次响应都可能换一个新令牌,调用方拿返回的会话接着用。
        public internal(set) var token: String
    }

    public struct Library: Codable, Equatable, Sendable, Identifiable, Hashable {
        public let id: Int
        public let name: String
        public let path: String?
        public let totalSongs: Int?

        public init(id: Int, name: String, path: String? = nil, totalSongs: Int? = nil) {
            self.id = id
            self.name = name
            self.path = path
            self.totalSongs = totalSongs
        }
    }

    public struct User: Equatable, Sendable, Identifiable {
        public let id: String
        public var userName: String
        public var name: String
        public var email: String
        public var isAdmin: Bool
        public let lastLoginAt: Date?
        public let lastAccessAt: Date?
        /// 0.58 之前没有多媒体库,这里是 nil。
        public let libraries: [Library]?

        public init(
            id: String, userName: String, name: String, email: String, isAdmin: Bool,
            lastLoginAt: Date? = nil, lastAccessAt: Date? = nil, libraries: [Library]? = nil
        ) {
            self.id = id
            self.userName = userName
            self.name = name
            self.email = email
            self.isAdmin = isAdmin
            self.lastLoginAt = lastLoginAt
            self.lastAccessAt = lastAccessAt
            self.libraries = libraries
        }
    }

    public struct NewUser: Sendable, Equatable {
        public var userName: String
        public var name: String
        public var email: String
        public var password: String
        public var isAdmin: Bool

        public init(userName: String, name: String, email: String = "", password: String, isAdmin: Bool = false) {
            self.userName = userName
            self.name = name
            self.email = email
            self.password = password
            self.isAdmin = isAdmin
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// 不是 Navidrome,或者这台服务器没开网页接口。
        case unavailable
        case notAdmin
        case authenticationFailed
        case accountMismatch
        case invalidResponse
        /// 服务器拒绝了这次修改,`message` 是它给的原因(用户名重复、密码太短……)。
        case rejected(status: Int, message: String?)
    }

    // MARK: 登录

    public static func login(
        baseURL: URL,
        username: String,
        password: String,
        load: RequestDataLoader
    ) async throws -> Session {
        var request = URLRequest(url: baseURL.appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if http.statusCode == 401 { throw Failure.authenticationFailed }
        if [403, 404, 405, 501].contains(http.statusCode) || http.mimeType == "text/html" { throw Failure.unavailable }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String, !id.isEmpty,
              let token = json["token"] as? String, !token.isEmpty,
              let name = json["username"] as? String else {
            throw Failure.invalidResponse
        }
        // 反向代理自动登录不能悄悄换成别人的账号。
        guard name.caseInsensitiveCompare(username) == .orderedSame else { throw Failure.accountMismatch }
        return Session(userID: id, username: name, isAdmin: json["isAdmin"] as? Bool ?? false, token: token)
    }

    // MARK: 用户

    public static func users(
        baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws -> [User] {
        try requireAdmin(session)
        let data = try await send(
            baseURL: baseURL, path: "api/user", method: "GET",
            query: ["_start": "0", "_end": "1000", "_sort": "userName", "_order": "ASC"],
            session: &session, load: load
        )
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Go 的空切片会写成 null。
            if String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) == "null" {
                return []
            }
            throw Failure.invalidResponse
        }
        return try array.map(decodeUser)
    }

    public static func createUser(
        _ newUser: NewUser, baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws -> User {
        try requireAdmin(session)
        let body: [String: Any] = [
            "userName": newUser.userName, "name": newUser.name, "email": newUser.email,
            "password": newUser.password, "isAdmin": newUser.isAdmin,
        ]
        let data = try await send(
            baseURL: baseURL, path: "api/user", method: "POST", body: body,
            session: &session, load: load
        )
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.invalidResponse
        }
        // 有的版本只回 `{"id": …}`,补上我们自己发出去的字段。
        if json["userName"] == nil, let id = json["id"] as? String {
            return User(id: id, userName: newUser.userName, name: newUser.name,
                        email: newUser.email, isAdmin: newUser.isAdmin)
        }
        return try decodeUser(json)
    }

    /// 改名称、邮箱、管理员身份;`newPassword` 不为 nil 时一起重置密码。
    /// 管理员改别人的密码不需要原密码;改自己的要 `currentPassword`。
    public static func updateUser(
        _ user: User, newPassword: String? = nil, currentPassword: String? = nil,
        baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws {
        try requireAdmin(session)
        var body: [String: Any] = [
            "id": user.id, "userName": user.userName, "name": user.name,
            "email": user.email, "isAdmin": user.isAdmin,
        ]
        if let newPassword, !newPassword.isEmpty { body["password"] = newPassword }
        if let currentPassword, !currentPassword.isEmpty { body["currentPassword"] = currentPassword }
        _ = try await send(
            baseURL: baseURL, path: "api/user/\(escaped(user.id))", method: "PUT", body: body,
            session: &session, load: load
        )
    }

    public static func deleteUser(
        id: String, baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws {
        try requireAdmin(session)
        guard id != session.userID else { throw Failure.rejected(status: 400, message: nil) }
        _ = try await send(
            baseURL: baseURL, path: "api/user/\(escaped(id))", method: "DELETE",
            session: &session, load: load
        )
    }

    // MARK: 媒体库(0.58 起)

    /// 服务器上的媒体库;老版本没有这个接口时返回 nil。
    public static func libraries(
        baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws -> [Library]? {
        try requireAdmin(session)
        let data: Data
        do {
            data = try await send(baseURL: baseURL, path: "api/library", method: "GET",
                                  session: &session, load: load)
        } catch Failure.unavailable {
            return nil
        }
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Failure.invalidResponse
        }
        return array.compactMap(decodeLibrary)
    }

    public static func setLibraries(
        _ ids: [Int], forUser userID: String,
        baseURL: URL, session: inout Session, load: RequestDataLoader
    ) async throws {
        try requireAdmin(session)
        _ = try await send(
            baseURL: baseURL, path: "api/user/\(escaped(userID))/library", method: "PUT",
            body: ["libraryIds": ids], session: &session, load: load
        )
    }

    // MARK: 内部

    private static func requireAdmin(_ session: Session) throws {
        guard session.isAdmin else { throw Failure.notAdmin }
    }

    private static func escaped(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? id
    }

    private static func send(
        baseURL: URL, path: String, method: String,
        query: [String: String] = [:], body: [String: Any]? = nil,
        session: inout Session, load: RequestDataLoader
    ) async throws -> Data {
        try Task.checkCancellation()
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false
        ) else { throw Failure.invalidResponse }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw Failure.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // Navidrome 认这个头,不认标准的 Authorization。
        request.setValue("Bearer \(session.token)", forHTTPHeaderField: "X-ND-Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalidResponse }
        if let refreshed = http.value(forHTTPHeaderField: "X-ND-Authorization"),
           refreshed.hasPrefix("Bearer "), refreshed.count > 7 {
            session.token = String(refreshed.dropFirst(7))
        }
        switch http.statusCode {
        case 200..<300:
            if http.mimeType == "text/html" { throw Failure.unavailable }
            return data
        case 401: throw Failure.authenticationFailed
        case 403: throw Failure.notAdmin
        case 404, 405, 501: throw Failure.unavailable
        default: throw Failure.rejected(status: http.statusCode, message: errorMessage(from: data))
        }
    }

    /// Navidrome 的校验错误长这样:`{"errors":{"userName":"ra.validation.unique"}}` 或 `{"error":"…"}`。
    static func errorMessage(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        }
        if let error = json["error"] as? String, !error.isEmpty { return error }
        if let errors = json["errors"] as? [String: Any] {
            let parts = errors.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)" }
            return parts.isEmpty ? nil : parts.joined(separator: "; ")
        }
        return nil
    }

    static func decodeUser(_ json: [String: Any]) throws -> User {
        guard let id = json["id"] as? String, !id.isEmpty,
              let userName = json["userName"] as? String else { throw Failure.invalidResponse }
        return User(
            id: id,
            userName: userName,
            name: json["name"] as? String ?? userName,
            email: json["email"] as? String ?? "",
            isAdmin: json["isAdmin"] as? Bool ?? false,
            lastLoginAt: date(json["lastLoginAt"]),
            lastAccessAt: date(json["lastAccessAt"]),
            libraries: (json["libraries"] as? [[String: Any]])?.compactMap(decodeLibrary)
        )
    }

    static func decodeLibrary(_ json: [String: Any]) -> Library? {
        guard let id = (json["id"] as? NSNumber)?.intValue, let name = json["name"] as? String else { return nil }
        return Library(
            id: id, name: name, path: json["path"] as? String,
            totalSongs: (json["totalSongs"] as? NSNumber)?.intValue
        )
    }

    /// Go 的时间带纳秒:`2026-05-01T10:00:00.123456789+08:00`。秒以下截到毫秒再解析;零值时间当没有。
    static func date(_ value: Any?) -> Date? {
        guard var text = value as? String, !text.isEmpty, !text.hasPrefix("0001-01-01") else { return nil }
        if let dot = text.firstIndex(of: "."),
           let zone = text[dot...].firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
            let fraction = text[text.index(after: dot)..<zone]
            text.replaceSubrange(dot..<zone, with: "." + fraction.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = text.contains(".")
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
