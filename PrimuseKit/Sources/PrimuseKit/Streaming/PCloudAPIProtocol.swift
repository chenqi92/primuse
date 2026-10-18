import Foundation

/// pCloud(pcloud.com)HTTP JSON 接口的请求约定与应答解析。
///
/// pCloud 按账号注册地把数据放在两个数据中心:美国 `api.pcloud.com`、欧洲
/// `eapi.pcloud.com`。两边是同一套接口、同一个 OAuth 应用,区别只在主机:授权页
/// (`my.pcloud.com/oauth2/authorize`)回跳时带 `locationid`(1 美国 / 2 欧洲)和
/// `hostname`,此后这个账号的每个请求都必须打到那台主机,打到另一区会被当成无效
/// token(2094)。所以不按地区分两套实现,每个音乐源记住自己的 API 主机就够了 ——
/// 它存在 token 的 `extra` 里,随钥匙串一起同步到别的设备。
///
/// OAuth token 不过期,也没有 refresh_token,用户在 pCloud 设置里撤销之前一直有效。
/// 应答一律 HTTP 200 + `{"result": 0, …}`,`result` 非 0 即业务错误,`error` 是说明。
/// token 走 `Authorization: Bearer` 头(实测与 `access_token` 参数等效),不进 URL。
///
/// 文件与文件夹用 pCloud 自己的字符串 ID 标识:文件 `f<fileid>`、文件夹 `d<folderid>`。
/// 两种数字 ID 各自编号、可能撞号,带前缀的才全局唯一,所以 `Song.filePath` 与目录
/// 标识都存带前缀的那个。根目录的 folderid 固定是 0。
public enum PCloudAPIProtocol {

    // MARK: - 主机

    public enum Region: Int, Sendable, CaseIterable {
        case unitedStates = 1
        case europe = 2

        public var apiHost: String {
            switch self {
            case .unitedStates: return PCloudAPIProtocol.unitedStatesAPIHost
            case .europe: return PCloudAPIProtocol.europeAPIHost
            }
        }
    }

    public static let unitedStatesAPIHost = "api.pcloud.com"
    public static let europeAPIHost = "eapi.pcloud.com"
    /// 没记下主机的凭据按美国区处理 —— pCloud 官方 SDK 对早期 token 也是这样兜底的。
    public static let defaultAPIHost = unitedStatesAPIHost
    public static let apiHosts = [unitedStatesAPIHost, europeAPIHost]

    /// token `extra` / `SourceCredential.extra` 里记 API 主机与地区的键。
    public static let apiHostKey = "pcloud_api_host"
    public static let locationIDKey = "pcloud_location_id"

    public static let authorizeURL = URL(string: "https://my.pcloud.com/oauth2/authorize")!

    /// 只接受 pcloud.com 之下的主机名。授权回调与轮询应答里的 hostname 决定 token
    /// 发往哪里,下载直链的主机也来自应答;不校验的话,一个伪造的回调就能把 token
    /// 引到别的服务器。
    public static func validatedHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard host.hasSuffix(".pcloud.com"), host.count <= 253 else { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 3 else { return nil }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.unicodeScalars.allSatisfy({ scalar in
                      ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
                  }) else { return nil }
        }
        return host
    }

    /// 授权结果里的 API 主机。`hostname` 是 pCloud 明说「之后都打这台」的那个,优先;
    /// 没给或不合法时按 `locationid` 换算;再不行用应答它的那台(轮询时才知道)。
    public static func apiHost(
        hostname: String?,
        locationID: String?,
        answeringHost: String? = nil
    ) -> String? {
        if let host = validatedHost(hostname) { return host }
        if let region = locationID
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
            .flatMap(Region.init(rawValue:)) {
            return region.apiHost
        }
        return validatedHost(answeringHost)
    }

    /// 已存凭据该连的主机。
    public static func apiHost(from extra: [String: String]?) -> String {
        apiHost(hostname: extra?[apiHostKey], locationID: extra?[locationIDKey]) ?? defaultAPIHost
    }

    public static func credentialExtra(apiHost: String, locationID: String?) -> [String: String] {
        var extra = [apiHostKey: apiHost]
        if let locationID, !locationID.isEmpty { extra[locationIDKey] = locationID }
        return extra
    }

    // MARK: - 标识

    public static let rootFolderID: Int64 = 0

    /// 目录标识 → folderid。浏览器根(`""` / `"/"`)、`d0`、裸数字都认。
    public static func folderID(from identifier: String) -> Int64? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "/" { return rootFolderID }
        let digits = trimmed.hasPrefix("d") ? String(trimmed.dropFirst()) : trimmed
        return unsignedID(digits)
    }

    /// 文件标识 → fileid。`f123` 与裸数字都认。
    public static func fileID(from identifier: String) -> Int64? {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = trimmed.hasPrefix("f") ? String(trimmed.dropFirst()) : trimmed
        return unsignedID(digits)
    }

    public static func isRootFolder(_ identifier: String) -> Bool {
        folderID(from: identifier) == rootFolderID
    }

    private static func unsignedID(_ digits: String) -> Int64? {
        guard !digits.isEmpty, digits.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
        return Int64(digits)
    }

    // MARK: - 接口地址

    /// 业务接口地址。`timeformat=timestamp` 让时间字段一律回 Unix 秒,不用解析 RFC 2822。
    static func methodURL(host: String, method: String, queryItems: [URLQueryItem] = []) -> URL? {
        guard let host = validatedHost(host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/" + method
        components.queryItems = queryItems + [URLQueryItem(name: "timeformat", value: "timestamp")]
        return FormSafeQueryURLBuilder.url(from: components)
    }

    public static func listFolderURL(host: String, folderID: Int64) -> URL? {
        methodURL(host: host, method: "listfolder", queryItems: [
            URLQueryItem(name: "folderid", value: String(folderID)),
        ])
    }

    public static func fileLinkURL(host: String, fileID: Int64) -> URL? {
        methodURL(host: host, method: "getfilelink", queryItems: [
            URLQueryItem(name: "fileid", value: String(fileID)),
        ])
    }

    public static func deleteFileURL(host: String, fileID: Int64) -> URL? {
        methodURL(host: host, method: "deletefile", queryItems: [
            URLQueryItem(name: "fileid", value: String(fileID)),
        ])
    }

    public static func userInfoURL(host: String) -> URL? {
        methodURL(host: host, method: "userinfo")
    }

    // MARK: - 授权

    /// 授权回调与轮询应答里拿到的一份授权。
    public struct Authorization: Sendable, Equatable {
        public let accessToken: String
        public let userID: String?
        public let apiHost: String
        public let locationID: String?

        public var credentialExtra: [String: String] {
            PCloudAPIProtocol.credentialExtra(apiHost: apiHost, locationID: locationID)
        }
    }

    /// 从扁平的键值(隐式授权回调的 fragment、轮询应答)里取授权。用户编号官方文档写
    /// `uid`,官方 SDK 读的是 `userid`,两个都认。主机定不下来就不算一份可用的授权。
    public static func authorization(
        from parameters: [String: String],
        answeringHost: String? = nil
    ) -> Authorization? {
        guard let token = parameters["access_token"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { return nil }
        let locationID = parameters["locationid"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let host = apiHost(
            hostname: parameters["hostname"],
            locationID: locationID,
            answeringHost: answeringHost
        ) else { return nil }
        let userID = [parameters["uid"], parameters["userid"]]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        return Authorization(
            accessToken: token,
            userID: userID,
            apiHost: host,
            locationID: locationID?.isEmpty == false ? locationID : nil
        )
    }

    /// 隐式授权(`response_type=token`)把结果放在回调 URL 的 fragment 里。
    public static func parameters(fromFragment fragment: String?) -> [String: String] {
        guard let fragment, !fragment.isEmpty else { return [:] }
        var components = URLComponents()
        components.percentEncodedQuery = fragment
        var parameters: [String: String] = [:]
        for item in components.queryItems ?? [] where parameters[item.name] == nil {
            parameters[item.name] = item.value ?? ""
        }
        return parameters
    }

    // MARK: 电视:poll_token 授权

    /// Apple TV 上的授权:pCloud 没有设备码接口,但授权页支持 `response_type=poll_token`
    /// —— 客户端自己生成一个 `request_id` 放进授权网址(电视把它画成二维码),用户在
    /// 任意浏览器里登录同意后,对 `oauth2_token?client_id=…&request_id=…` 挂着的那个
    /// 请求直接返回 token。轮询请求在授权前一直挂起(实测几分钟不回),不是立即回
    /// pending;用户属于哪个区事先不知道,所以两区同时挂,谁先回用谁。
    /// 这条路文档页没写,出自 pCloud 官方 JS SDK 的 `initOauthPollToken`;授权页模板
    /// 与 `oauth2_token` 的报错(「Please provide 'code' or 'request_id'.」)都认这个参数。
    public static func pollAuthorizeURL(clientID: String, requestID: String) -> URL? {
        var components = URLComponents(url: authorizeURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "poll_token"),
            URLQueryItem(name: "request_id", value: requestID),
        ]
        return components.flatMap(FormSafeQueryURLBuilder.url(from:))
    }

    public static func pollTokenURL(host: String, clientID: String, requestID: String) -> URL? {
        guard let host = validatedHost(host) else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = "/oauth2_token"
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "request_id", value: requestID),
        ]
        return FormSafeQueryURLBuilder.url(from: components)
    }

    /// 电视上的二维码保留多久。pCloud 没有给 request_id 定有效期,这里取一个
    /// 足够用户掏出手机登录、又不至于让电视空等太久的时长。
    public static let pollAuthorizationLifetime: TimeInterval = 600
    public static let requestIDLength = 40

    /// 与官方 SDK 一样取 40 位字母数字。它同时是取 token 的凭证,只能用系统随机源。
    public static func makeRequestID() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<requestIDLength).map { _ in alphabet.randomElement(using: &generator)! })
    }

    public enum PollOutcome: Sendable, Equatable {
        case authorized(Authorization)
        case rejected(Envelope)
    }

    public static func parsePollResponse(_ data: Data, answeringHost: String) -> PollOutcome? {
        guard let json = object(data) else { return nil }
        let envelope = envelope(json)
        guard envelope.isSuccess else { return .rejected(envelope) }
        var flattened: [String: String] = [:]
        for key in ["access_token", "hostname", "locationid", "uid", "userid"] {
            if let value = scalarString(json[key]) { flattened[key] = value }
        }
        return authorization(from: flattened, answeringHost: answeringHost).map(PollOutcome.authorized)
    }

    // MARK: - 应答

    public enum ResultCode {
        public static let loginRequired = 1000
        public static let loginFailed = 2000
        public static let accessDenied = 2003
        public static let directoryNotFound = 2005
        public static let fileNotFound = 2009
        public static let invalidAccessToken = 2094
        public static let tooManyLoginTries = 4000
    }

    /// 没带 token、token 无效、被撤销。pCloud 的 token 不能刷新,遇到只能重新授权。
    public static func indicatesInvalidToken(_ code: Int) -> Bool {
        code == ResultCode.loginRequired
            || code == ResultCode.loginFailed
            || code == ResultCode.invalidAccessToken
    }

    /// 4xxx 是限频,5xxx 是服务端临时故障,官方说明两类都该过一会儿再试。
    public static func isTransient(_ code: Int) -> Bool {
        (4000..<6000).contains(code)
    }

    public static func indicatesMissingItem(_ code: Int) -> Bool {
        code == ResultCode.directoryNotFound || code == ResultCode.fileNotFound
    }

    public struct Envelope: Sendable, Equatable {
        public let result: Int
        public let message: String
        public var isSuccess: Bool { result == 0 }
    }

    public static func parseEnvelope(_ data: Data) -> Envelope? {
        object(data).map(envelope)
    }

    /// 一个文件或文件夹。
    public struct Entry: Sendable, Equatable {
        /// 带前缀的 ID:文件 `f…`,文件夹 `d…`。
        public let id: String
        public let name: String
        public let isFolder: Bool
        public let size: Int64
        public let modifiedAt: Date?
        /// 内容哈希(64 位整数)。内容一变它就变,用作文件版本标识。
        public let contentHash: String?
    }

    /// `listfolder` 的直接子项。单条读不出来就跳过,不让一行脏数据拖垮整个目录。
    public static func parseFolderListing(_ data: Data) -> [Entry]? {
        guard let json = object(data), envelope(json).isSuccess,
              let metadata = json["metadata"] as? [String: Any] else { return nil }
        guard let contents = metadata["contents"] as? [Any] else { return [] }
        return contents.compactMap { ($0 as? [String: Any]).flatMap(entry) }
    }

    static func entry(_ item: [String: Any]) -> Entry? {
        guard let name = item["name"] as? String, !name.isEmpty else { return nil }
        let isFolder = bool(item["isfolder"]) ?? false
        let prefix = isFolder ? "d" : "f"
        let id: String
        if let raw = item["id"] as? String, raw.hasPrefix(prefix),
           unsignedID(String(raw.dropFirst())) != nil {
            id = raw
        } else if let number = int64(item[isFolder ? "folderid" : "fileid"]), number >= 0 {
            id = prefix + String(number)
        } else {
            return nil
        }
        return Entry(
            id: id,
            name: name,
            isFolder: isFolder,
            size: isFolder ? 0 : max(0, int64(item["size"]) ?? 0),
            modifiedAt: double(item["modified"]).map { Date(timeIntervalSince1970: $0) },
            contentHash: isFolder ? nil : scalarString(item["hash"])
        )
    }

    /// `getfilelink` 给的直链。直链自带有效期,下载时不再需要 token。
    public struct FileLink: Sendable, Equatable {
        public let url: URL
        public let expiresAt: Date?
    }

    /// 直链是 `https://` + `hosts` 里的一台 + `path`,第一台是 pCloud 认为最好的那台。
    public static func parseFileLink(_ data: Data) -> FileLink? {
        guard let json = object(data), envelope(json).isSuccess,
              let path = json["path"] as? String, path.hasPrefix("/"),
              let hosts = json["hosts"] as? [Any] else { return nil }
        let expiresAt = double(json["expires"]).map { Date(timeIntervalSince1970: $0) }
        for case let raw as String in hosts {
            guard let host = validatedHost(raw),
                  let url = URL(string: "https://\(host)\(path)"),
                  url.host?.lowercased() == host else { continue }
            return FileLink(url: url, expiresAt: expiresAt)
        }
        return nil
    }

    public struct UserInfo: Sendable, Equatable {
        public let userID: String
        public let email: String?
    }

    public static func parseUserInfo(_ data: Data) -> UserInfo? {
        guard let json = object(data), envelope(json).isSuccess,
              let userID = scalarString(json["userid"]) else { return nil }
        return UserInfo(userID: userID, email: json["email"] as? String)
    }

    /// `deletefile` 成功时回被删文件的元数据,并带 `isdeleted: true`。
    public static func confirmsDeletion(_ data: Data) -> Bool {
        guard let json = object(data), envelope(json).isSuccess,
              let metadata = json["metadata"] as? [String: Any] else { return false }
        return bool(metadata["isdeleted"]) == true
    }

    // MARK: - JSON 小工具

    private static func object(_ data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func envelope(_ json: [String: Any]) -> Envelope {
        // 没有 result 字段的应答不是 pCloud 的业务应答,按失败处理,免得把它当成功解析。
        Envelope(
            result: int64(json["result"]).map { Int(clamping: $0) } ?? -1,
            message: (json["error"] as? String) ?? ""
        )
    }

    private static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }

    private static func double(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let text = value as? String { return Double(text) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        return nil
    }

    /// 数字或字符串字段转成文本。64 位哈希可能超过 Int64,用 NSNumber 的原样文本。
    private static func scalarString(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
