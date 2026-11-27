import Foundation
import PrimuseKit

/// Google Drive 的访问方式与已选文件:每次列目录前按源上存的访问方式和令牌判断怎么列、半迁移时
/// 报错要求重新选择;账号标识;已授权文件的列表、这一轮的快照和同目录查找;权限范围不够的识别。
extension GoogleDriveSource {
    /// 令牌附加字段。钥匙串此刻读不出来时抛读取错误:答不了,不当成「没有」。
    private func tokenExtra() async throws -> [String: String]? {
        if let tokenExtraProvider { return try await tokenExtraProvider() }
        if tokenProvider != nil { return nil }
        switch await helper.tokenManager.lookupTokens() {
        case .found(let tokens): return tokens.extra
        case .notFound: return nil
        case .temporarilyUnavailable(let status): throw CloudDriveError.credentialTemporarilyUnavailable(status)
        case .failed(let status): throw CloudDriveError.credentialReadFailed(status)
        }
    }

    /// 每次列目录、对账之前确认这次按哪种方式列。半迁移状态抛「需要重新选择文件」,不返回不完整的
    /// 列表:列不到的歌在扫描里会被当成已经删掉。`path` 为 nil 表示与目录无关的调用。
    func resolvedAccessMode(forPath path: String?) async throws -> GoogleDrivePickerPolicy.AccessMode {
        let extra = try await tokenExtra()
        switch GoogleDrivePickerPolicy.listingDecision(
            storedMode: storedAccessMode,
            tokenExtra: .found(extra),
            path: path
        ) {
        case .legacyFolders:
            return .legacyFullDrive
        case .pickedFiles:
            return .pickedFiles
        case .requiresReselection:
            plog("⛔ Google Drive source=\(sourceID.prefix(8))… stored=\(storedAccessMode?.rawValue ?? "nil") token=\(GoogleDrivePickerPolicy.grantedScope(forTokenExtra: extra)) path=\(path ?? "-"): files must be chosen again")
            throw SourceRootResolutionError.pickedFilesReselectionRequired
        case .cannotAnswer:
            // `tokenExtra()` 已经把读不出来抛成钥匙串错误,这里只是兜底。
            throw CloudDriveError.credentialReadFailed(-1)
        }
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    struct AccountIdentity: Sendable, Equatable {
        let uid: String
        let email: String?
    }

    func accountIdentifier() async throws -> String {
        try await accountIdentity().uid
    }

    /// 已选文件模式(或者令牌只有 `drive.file`,不能读 OIDC userinfo)读 Drive
    /// `about?fields=user(permissionId,emailAddress)`,不需要额外的权限范围;整盘源照旧读
    /// OIDC `userinfo` 的 `sub`,403 时退到 `about`。邮箱只用来判断重新授权是不是换了账号。
    func accountIdentity() async throws -> AccountIdentity {
        let token = try await getToken()
        let extra = try await tokenExtra()
        if GoogleDrivePickerPolicy.effectiveMode(stored: storedAccessMode) == .pickedFiles
            || GoogleDrivePickerPolicy.grantedScope(forTokenExtra: extra) == .filesOnly {
            return try await driveAboutIdentity(token: token)
        }
        let url = URL(string: "https://www.googleapis.com/oauth2/v3/userinfo")!
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: url, accessToken: tok)
        }
        if http.statusCode == 403 {
            return try await driveAboutIdentity(token: token)
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let sub = json["sub"] as? String, !sub.isEmpty else {
            plog("⚠️ Google accountIdentifier: missing sub in response: \(json)")
            throw CloudDriveError.invalidResponse
        }
        return AccountIdentity(uid: sub, email: json["email"] as? String)
    }

    private func driveAboutIdentity(token: String) async throws -> AccountIdentity {
        var components = URLComponents(string: "\(Self.apiBase)/about")!
        components.queryItems = [.init(name: "fields", value: "user(permissionId,emailAddress)")]
        let url = components.url!
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: url, accessToken: tok)
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let user = json["user"] as? [String: Any],
              let permissionID = user["permissionId"] as? String,
              !permissionID.isEmpty else {
            plog("⚠️ Google accountIdentifier: missing user.permissionId in about response")
            throw CloudDriveError.invalidResponse
        }
        return AccountIdentity(uid: permissionID, email: user["emailAddress"] as? String)
    }

    /// 授权预览:用还没存下的新令牌列出这次能看到的已授权文件 ID。上界是这个账号给 Primuse 的已授权文件数。
    func authorizedFileIDs() async throws -> Set<String> {
        Set(try await refreshAuthorizedFilesSnapshot().map(\.path))
    }

    /// 同目录的文件。已选文件模式下从这一轮的已授权文件快照里筛;`fresh` 时重列一遍(写回之后核对
    /// 有没有别处同时写了同名文件)。
    func siblingsInFolder(_ parentID: String, fresh: Bool = false) async throws -> [RemoteFileItem] {
        if try await resolvedAccessMode(forPath: nil) == .pickedFiles {
            let authorized: [RemoteFileItem]
            if !fresh, let snapshot = authorizedFilesSnapshot,
               Date().timeIntervalSince(snapshot.listedAt) < Self.authorizedFilesSnapshotLifetime {
                authorized = snapshot.items
            } else {
                authorized = try await refreshAuthorizedFilesSnapshot()
            }
            return authorized.filter { $0.parentPath == parentID }
        }
        return try await listFiles(at: parentID)
    }

    /// 写回的歌词、封面是 Primuse 自己建的文件,`drive.file` 下也属于已授权文件:记进快照,
    /// 同一轮后面的查找不用为它重列。
    func noteUploadedSidecar(id: String, name: String, parentID: String, size: Int64) {
        guard let snapshot = authorizedFilesSnapshot else { return }
        var items = snapshot.items.filter { $0.path != id }
        items.append(RemoteFileItem(
            name: name, path: id, isDirectory: false, size: size, modifiedDate: Date(),
            providerID: id, parentPath: parentID
        ))
        authorizedFilesSnapshot = AuthorizedFilesSnapshot(items: items, listedAt: snapshot.listedAt)
    }

    /// 列一遍已授权文件(加上令牌里记着、列表没带回来的已选文件),存成这一轮的快照。
    func refreshAuthorizedFilesSnapshot() async throws -> [RemoteFileItem] {
        var rawItems = try await listFilesMatching(
            query: GoogleDrivePickerPolicy.authorizedFilesQuery,
            fallbackParentPath: nil,
            notFoundTarget: GoogleDrivePickerPolicy.authorizedFilesRootPath,
            isLegacyFolderListing: false
        )
        let pickedIDs = GoogleDrivePickerPolicy.parsePickedFileIDs(
            from: try await tokenExtra()?[GoogleDrivePickerPolicy.pickedFileIDsExtraKey]
        )
        if !pickedIDs.isEmpty {
            // 上界是已选文件数。
            var knownIDs = Set(rawItems.map(\.path))
            for fileID in pickedIDs where !knownIDs.contains(fileID) {
                if let item = try await fetchAuthorizedFile(id: fileID) {
                    rawItems.append(item)
                    knownIDs.insert(fileID)
                }
            }
        }
        authorizedFilesSnapshot = AuthorizedFilesSnapshot(items: rawItems, listedAt: Date())
        return rawItems
    }

    private func fetchAuthorizedFile(id: String) async throws -> RemoteFileItem? {
        var components = URLComponents(string: "\(Self.apiBase)/files/\(id)")!
        components.queryItems = [
            .init(name: "fields", value: "id,name,mimeType,size,modifiedTime,md5Checksum,headRevisionId,parents,trashed"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        let (data, http) = try await requestListPage(components.url!)
        if http.statusCode == 403 || http.statusCode == 404 {
            return nil
        }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["trashed"] as? Bool != true,
              (json["mimeType"] as? String) != "application/vnd.google-apps.folder" else {
            return nil
        }
        return try? Self.parseRemoteFileItem(json, fallbackParentPath: nil)
    }

    /// Google 对「令牌的权限范围不够」的回答:`ACCESS_TOKEN_SCOPE_INSUFFICIENT`,或
    /// "Request had insufficient authentication scopes."。
    nonisolated static func isInsufficientScopeFailure(_ data: Data) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data.prefix(16 * 1024))) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return false }
        let details = error["details"] as? [[String: Any]] ?? []
        if details.contains(where: { ($0["reason"] as? String) == "ACCESS_TOKEN_SCOPE_INSUFFICIENT" }) {
            return true
        }
        let message = (error["message"] as? String)?.lowercased() ?? ""
        return message.contains("insufficient authentication scopes")
    }
}
