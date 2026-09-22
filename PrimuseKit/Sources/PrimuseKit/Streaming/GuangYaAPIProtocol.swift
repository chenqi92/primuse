import CryptoKit
import Foundation

/// 光鸭云盘(guangyapan.com)开放平台的请求约定与应答解析。
///
/// 开放平台分两个域:授权走 `openapi-account.guangyapan.com`,业务接口走
/// `openapi.guangyapan.com`。业务接口除 `Authorization: Bearer` 外还要求
/// `client_id` / `timestamp` / `sign` 三个头,`sign` 是
/// `MD5("client_id=…&timestamp=…&secret=<sign_secret>")`,服务端允许的时钟偏差
/// 是 300 秒。
///
/// 接入方信息(client_id / project_id / sign_secret)由平台分配,构建期经
/// xcconfig 注入 Info.plist,不落在源码里。
///
/// 此处实现列目录、文件详情、加签直链和用户信息。OpenAPI v1.3 的上传接口
/// 需要平台单独开通，且未定义覆盖 / 删除已落盘文件，尚不能用于原文件写回。
public enum GuangYaAPIProtocol {

    // MARK: - 环境

    public static let apiBaseURL = URL(string: "https://openapi.guangyapan.com")!
    public static let accountBaseURL = URL(string: "https://openapi-account.guangyapan.com")!

    /// Web OAuth 2.0 + PKCE 授权页。iPhone / Mac 用 ASWebAuthenticationSession 打开。
    public static let webAuthorizeURL = "https://www.guangyapan.com/oauth/"
    /// 授权范围固定 `user offline`,`offline` 决定能否拿到 refresh_token。
    public static let scopes = ["user", "offline"]

    public static var tokenURL: URL { accountBaseURL.appending(path: "v1/auth/token") }
    public static var deviceCodeURL: URL { accountBaseURL.appending(path: "v1/auth/device/code") }

    public static var fileListPath: String { "openapi/v1/file/get_file_list" }
    public static var fileDetailPath: String { "openapi/v1/file/get_file_detail" }
    public static var downloadURLPath: String { "openapi/v1/file/get_res_download_url" }
    public static var vodURLPath: String { "openapi/v1/file/get_vod_download_url" }
    public static var userInfoPath: String { "openapi/v1/user/get_user_info" }

    /// 列表接口限频 5 次/秒/IP,其余业务接口 2 次/秒/IP。连接器按这个间隔自我节流,
    /// 免得整库扫描把服务端打到限频。间隔取的是比限频上限更慢的一档:厂商文档
    /// 明确要求给并发留余量,踩着 5 次/秒、2 次/秒发请求时,服务端按秒计窗口
    /// 只要和客户端错开一点就会判超,整库扫描会被 429 打断。
    public static let fileListMinimumInterval: TimeInterval = 0.25
    public static let defaultMinimumInterval: TimeInterval = 0.6

    /// 撞到限频后整条闸门冷却这么久。单请求各自退避挡不住限频:并发的其他请求
    /// 仍在按原间隔发,服务端看到的还是超限的流量。
    public static let rateLimitCooldown: TimeInterval = 2.0

    /// 单页条数。列表接口 `pageSize` 必填,但文档没有写上限 —— 取一个网盘普遍
    /// 接受的值,并让翻页逻辑容忍服务端把它截短。
    public static let defaultPageSize = 100

    /// 翻页的硬上限,防止服务端 `total` 与实际返回长期对不上时无限翻页。
    public static let maximumFileListPages = 2_000
    /// 排序:按更新时间降序,和光鸭网页端默认一致。
    public static let defaultOrderBy = 3
    public static let defaultSortType = 1

    /// `resType`:1 = 文件,2 = 文件夹。
    public static let resTypeFile = 1
    public static let resTypeDirectory = 2

    // MARK: - 业务错误码

    public enum ResultCode {
        public static let success = 0
        public static let internalError = 101
        public static let accessDenied = 111
        public static let invalidParameter = 112
        public static let invalidSign = 116
        public static let invalidAccessToken = 117
        public static let invalidClientID = 120
        public static let fileNotFound = 146
        public static let fileDeleted = 149
        public static let vipRequiredForResolution = 164
        public static let fileNotConsumable = 167
        public static let notMember = 430
    }

    /// 该业务码是否代表「access_token 失效」——调用方据此刷新 token 后重试一次。
    public static func indicatesInvalidToken(code: Int) -> Bool {
        code == ResultCode.invalidAccessToken
    }

    /// HTTP 层的鉴权失败。业务码 116(签名无效)是 HTTP 200,不在此列。
    public static func indicatesInvalidToken(httpStatusCode: Int) -> Bool {
        httpStatusCode == 401
    }

    // MARK: - 接入方信息

    /// 平台分配给接入方的三件套。`signSecret` 只用于生成业务接口的 `sign` 头,
    /// 不会出现在任何授权请求体里。
    public struct AppConfig: Sendable, Equatable {
        public let clientID: String
        public let projectID: String
        public let signSecret: String

        public init(clientID: String, projectID: String, signSecret: String) {
            self.clientID = clientID
            self.projectID = projectID
            self.signSecret = signSecret
        }
    }

    public static let clientIDInfoKey = "PrimuseGuangYaClientID"
    public static let projectIDInfoKey = "PrimuseGuangYaProjectID"
    public static let signSecretInfoKey = "PrimuseGuangYaSignSecret"

    /// 从主 Bundle 的 Info.plist 读取构建期注入的接入方信息。三项缺任何一项都
    /// 返回 nil —— 少了 project_id 拿不到设备码,少了 sign_secret 业务接口必回 116。
    public static func bundledAppConfig(bundle: Bundle = .main) -> AppConfig? {
        guard let clientID = infoValue(clientIDInfoKey, bundle: bundle),
              let projectID = infoValue(projectIDInfoKey, bundle: bundle),
              let signSecret = infoValue(signSecretInfoKey, bundle: bundle) else {
            return nil
        }
        return AppConfig(clientID: clientID, projectID: projectID, signSecret: signSecret)
    }

    private static func infoValue(_ key: String, bundle: Bundle) -> String? {
        guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - 设备标识

    public static let deviceIdentifierDefaultsKey = "primuse.guangya.deviceID"

    /// 设备码授权要求一个稳定的 32 位十六进制设备 ID。首次生成后落 UserDefaults,
    /// 之后每次授权/刷新都用同一个,便于服务端识别同一台设备。
    public static func deviceIdentifier(defaults: UserDefaults = .standard) -> String {
        if let stored = defaults.string(forKey: deviceIdentifierDefaultsKey),
           let normalized = normalizedDeviceIdentifier(stored) {
            return normalized
        }
        let generated = randomDeviceIdentifier()
        defaults.set(generated, forKey: deviceIdentifierDefaultsKey)
        return generated
    }

    /// 只接受 32 位小写十六进制;带连字符的 UUID 会被规整掉。
    public static func normalizedDeviceIdentifier(_ value: String) -> String? {
        let condensed = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
        guard condensed.count == 32,
              condensed.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return condensed
    }

    public static func randomDeviceIdentifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - 请求签名

    /// `sign = MD5("client_id={client_id}&timestamp={timestamp}&secret={sign_secret}")`。
    /// 参数顺序、参数名、间隔符都不能动,MD5 结果也不再做二次编码。
    public static func signature(
        clientID: String,
        timestamp: String,
        signSecret: String
    ) -> String {
        let raw = "client_id=\(clientID)&timestamp=\(timestamp)&secret=\(signSecret)"
        return Insecure.MD5.hash(data: Data(raw.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    public static func timestamp(at date: Date = Date()) -> String {
        String(Int64(date.timeIntervalSince1970))
    }

    /// 业务接口的公共头。`traceparent` 传 nil 时自动生成一条,便于服务端追踪问题。
    public static func businessHeaders(
        accessToken: String,
        config: AppConfig,
        date: Date = Date(),
        traceparent: String? = nil
    ) -> [String: String] {
        let stamp = timestamp(at: date)
        return [
            "Authorization": "Bearer \(accessToken)",
            "client_id": config.clientID,
            "timestamp": stamp,
            "sign": signature(
                clientID: config.clientID,
                timestamp: stamp,
                signSecret: config.signSecret
            ),
            "traceparent": traceparent ?? makeTraceparent(),
            "Accept": "application/json",
        ]
    }

    /// W3C Trace Context:`00-<32 hex trace>-<16 hex span>-01`。
    public static func makeTraceparent() -> String {
        func hex(_ count: Int) -> String {
            (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
        }
        return "00-\(hex(16))-\(hex(8))-01"
    }

    // MARK: - 授权请求

    /// 设备码接口的专属头。`x-project-id` 缺失时服务端直接拒绝发码。
    public static func deviceAuthHeaders(config: AppConfig, deviceID: String) -> [String: String] {
        [
            "Content-Type": "application/json",
            "Accept": "application/json",
            "x-client-id": config.clientID,
            "x-device-id": deviceID,
            "x-project-id": config.projectID,
        ]
    }

    public static func deviceCodeBody(config: AppConfig, scope: String = "") -> [String: Any] {
        ["scope": scope, "client_id": config.clientID, "project_id": config.projectID]
    }

    public static func deviceTokenBody(config: AppConfig, deviceCode: String) -> [String: Any] {
        [
            "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
            "device_code": deviceCode,
            "client_id": config.clientID,
        ]
    }

    public static func refreshTokenBody(clientID: String, refreshToken: String) -> [String: Any] {
        ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
    }

    /// iPhone / iPad / Mac 上把用户送进已安装的光鸭云盘 App 完成授权。
    /// 没装 App 时调用方回落到把 `verificationURLComplete` 交给浏览器或画成二维码。
    public static func appAuthorizationDeepLink(verificationURLComplete: String) -> URL? {
        let trimmed = verificationURLComplete.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let encoded = trimmed.addingPercentEncoding(
                withAllowedCharacters: CharacterSet(charactersIn:
                    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
              ) else { return nil }
        return URL(string: "gyp://auth?url=\(encoded)")
    }

    // MARK: - 业务接口 URL

    public static func fileListURL(
        parentID: String?,
        page: Int,
        pageSize: Int = defaultPageSize,
        orderBy: Int = defaultOrderBy,
        sortType: Int = defaultSortType
    ) -> URL? {
        var items = [
            URLQueryItem(name: "page", value: String(max(0, page))),
            URLQueryItem(name: "pageSize", value: String(max(1, pageSize))),
            URLQueryItem(name: "orderBy", value: String(orderBy)),
            URLQueryItem(name: "sortType", value: String(sortType)),
        ]
        if let parentID, !isRootIdentifier(parentID) {
            items.insert(URLQueryItem(name: "parentId", value: parentID), at: 0)
        }
        return url(path: fileListPath, queryItems: items)
    }

    public static func fileDetailURL(fileID: String) -> URL? {
        url(path: fileDetailPath, queryItems: [URLQueryItem(name: "fileId", value: fileID)])
    }

    public static func downloadURL(fileID: String) -> URL? {
        url(path: downloadURLPath, queryItems: [URLQueryItem(name: "fileId", value: fileID)])
    }

    public static var userInfoURL: URL? {
        url(path: userInfoPath, queryItems: [])
    }

    /// 根目录在光鸭侧没有独立 ID:不传 `parentId` 即为根。Primuse 内部用 "" 或 "/"
    /// 表示根,两者都要归一,否则同一个目录会被当成两个扫描根。
    public static func isRootIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "/" || trimmed == "0"
    }

    private static func url(path: String, queryItems: [URLQueryItem]) -> URL? {
        guard var components = URLComponents(
            url: apiBaseURL.appending(path: path),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        return queryItems.isEmpty
            ? components.url
            : FormSafeQueryURLBuilder.url(from: components)
    }

    // MARK: - 应答解析

    public struct FileEntry: Sendable, Equatable {
        public let fileID: String
        public let fileName: String
        public let parentID: String?
        public let size: Int64
        public let isDirectory: Bool
        public let bizID: String?
        public let fileType: Int?
        public let fileExtension: String?
        public let createdAt: Date?
        public let thumbnail: String?

        public init(
            fileID: String,
            fileName: String,
            parentID: String?,
            size: Int64,
            isDirectory: Bool,
            bizID: String?,
            fileType: Int?,
            fileExtension: String?,
            createdAt: Date?,
            thumbnail: String?
        ) {
            self.fileID = fileID
            self.fileName = fileName
            self.parentID = parentID
            self.size = size
            self.isDirectory = isDirectory
            self.bizID = bizID
            self.fileType = fileType
            self.fileExtension = fileExtension
            self.createdAt = createdAt
            self.thumbnail = thumbnail
        }
    }

    public struct FileListPage: Sendable, Equatable {
        public let total: Int
        public let entries: [FileEntry]

        public init(total: Int, entries: [FileEntry]) {
            self.total = total
            self.entries = entries
        }
    }

    public struct DownloadTicket: Sendable, Equatable {
        public let url: URL
        /// 直链有效期(秒)。直链是临时的,过期要重新取,不能长期缓存。
        public let duration: TimeInterval

        public init(url: URL, duration: TimeInterval) {
            self.url = url
            self.duration = duration
        }
    }

    public struct UserInfo: Sendable, Equatable {
        public let userID: String
        public let nickName: String?
        public let totalSpace: Int64?
        public let usedSpace: Int64?

        public init(userID: String, nickName: String?, totalSpace: Int64?, usedSpace: Int64?) {
            self.userID = userID
            self.nickName = nickName
            self.totalSpace = totalSpace
            self.usedSpace = usedSpace
        }
    }

    /// 通用信封 `{code, msg, data}`。`code != 0` 时 `data` 通常为 null。
    public struct Envelope: Sendable, Equatable {
        public let code: Int
        public let message: String

        public init(code: Int, message: String) {
            self.code = code
            self.message = message
        }

        public var isSuccess: Bool { code == ResultCode.success }
    }

    public static func parseEnvelope(_ data: Data) -> Envelope? {
        guard let json = jsonObject(data), let code = intValue(json["code"]) else { return nil }
        return Envelope(code: code, message: stringValue(json["msg"]) ?? "")
    }

    public static func parseFileList(_ data: Data) -> FileListPage? {
        guard let payload = successPayload(data) else { return nil }
        guard let list = payload["list"] as? [[String: Any]] else {
            // 空目录可能直接返回 {"total":0} 而没有 list 字段。
            guard let total = intValue(payload["total"]), total == 0 else { return nil }
            return FileListPage(total: 0, entries: [])
        }
        let entries = list.compactMap(parseFileEntry)
        // 单个条目解析不出来(缺 fileId / fileName / resType 的异常行)只跳过它,
        // 不把整页判成解析失败 —— 整页失败会让这个目录连同整次扫描一起报错,
        // 用户侧的表现是「歌进来了但没有文件夹」外加反复重试。整页都读不出
        // 条目时才当成应答不可用。
        guard !entries.isEmpty || list.isEmpty else { return nil }
        return FileListPage(total: intValue(payload["total"]) ?? entries.count, entries: entries)
    }

    /// 是否还要继续翻下一页。
    ///
    /// 不能只看「本页不满 pageSize 就是到底」:`pageSize` 的上限文档没写,服务端
    /// 有权把它截短,那样每个目录都只会扫到第一页。以服务端自己给的 `total`
    /// 为准,拿不到 total 时才回落到满页判断;空页与页数上限兜住异常应答。
    public static func shouldRequestNextPage(
        receivedCount: Int,
        accumulatedCount: Int,
        reportedTotal: Int?,
        requestedPageSize: Int,
        nextPage: Int,
        pageLimit: Int = maximumFileListPages
    ) -> Bool {
        guard receivedCount > 0, nextPage < pageLimit else { return false }
        if let reportedTotal, reportedTotal > 0 {
            return accumulatedCount < reportedTotal
        }
        return receivedCount >= max(1, requestedPageSize)
    }

    public static func parseFileDetail(_ data: Data) -> FileEntry? {
        guard let payload = successPayload(data),
              let info = payload["fileInfo"] as? [String: Any] else { return nil }
        return parseFileEntry(info)
    }

    public static func parseFileEntry(_ item: [String: Any]) -> FileEntry? {
        guard let fileID = stringValue(item["fileId"]), !fileID.isEmpty,
              let fileName = stringValue(item["fileName"]), !fileName.isEmpty,
              let resType = intValue(item["resType"]) else { return nil }
        let isDirectory = resType == resTypeDirectory
        let created = intValue(item["ctime"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil }
        return FileEntry(
            fileID: fileID,
            fileName: fileName,
            parentID: stringValue(item["parentId"]),
            size: isDirectory ? 0 : (int64Value(item["fileSize"]) ?? 0),
            isDirectory: isDirectory,
            bizID: stringValue(item["bizId"]),
            fileType: intValue(item["fileType"]),
            fileExtension: stringValue(item["ext"]),
            createdAt: created,
            thumbnail: stringValue(item["thumbnail"])
        )
    }

    public static func parseDownloadTicket(_ data: Data) -> DownloadTicket? {
        guard let payload = successPayload(data),
              let link = stringValue(payload["signedURL"]) ?? stringValue(payload["downloadUrl"]),
              let url = URL(string: link) else { return nil }
        let duration = intValue(payload["urlDuration"]).map(TimeInterval.init) ?? 0
        return DownloadTicket(url: url, duration: duration)
    }

    public static func parseUserInfo(_ data: Data) -> UserInfo? {
        guard let payload = successPayload(data),
              let userID = stringValue(payload["userId"]), !userID.isEmpty else { return nil }
        return UserInfo(
            userID: userID,
            nickName: stringValue(payload["nickName"]),
            totalSpace: int64Value(payload["totalSpace"]),
            usedSpace: int64Value(payload["usedSpace"])
        )
    }

    private static func successPayload(_ data: Data) -> [String: Any]? {
        guard let json = jsonObject(data),
              intValue(json["code"]) == ResultCode.success,
              let payload = json["data"] as? [String: Any] else { return nil }
        return payload
    }

    // MARK: - JSON 小工具

    private static func jsonObject(_ data: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// ID 字段在不同接口里可能是字符串也可能是数字,统一取字符串。
    private static func stringValue(_ value: Any?) -> String? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let text = value as? String { return Int64(text) }
        return nil
    }
}
