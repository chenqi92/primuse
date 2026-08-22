import Foundation
import PrimuseKit

/// OneDrive Source — Microsoft Graph API
actor OneDriveSource: MusicSourceConnector, OAuthCloudSource, RemoteFileDisplayNameProviding,
    IncrementalMusicSourceConnector, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削的歌词/封面写回 OneDrive(上传 sidecar)
    private let helper: CloudDriveHelper
    private static let graphBase = "https://graph.microsoft.com/v1.0"
    private static let authBase = "https://login.microsoftonline.com/common/oauth2/v2.0"
    private static let fallbackRedirectURI = "\(CloudOAuthConfig.callbackScheme)://onedrive/callback"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws { _ = try await getToken() }

    /// Microsoft Graph `/me` returns the signed-in user record. The `id`
    /// field is the Azure AD object identifier — stable across token
    /// refresh and across devices logged into the same Microsoft account.
    /// `$select=id` keeps the response tiny.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.graphBase)/me?$select=id")!,
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let id = json["id"] as? String, !id.isEmpty else {
            plog("⚠️ OneDrive accountIdentifier: missing id in response: \(json)")
            throw CloudDriveError.invalidResponse
        }
        return id
    }
    func disconnect() async {}

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
    }

    private static func metadataState(
        itemID: String,
        accessToken: String
    ) async throws -> EmbeddedMetadataRemoteFileState {
        var components = URLComponents(
            string: "\(graphBase)/me/drive/items/\(itemID)"
        )!
        components.queryItems = [
            .init(name: "$select", value: "id,size,eTag,lastModifiedDateTime,file"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 404 { throw CloudDriveError.fileNotFound(itemID) }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["file"] != nil,
              let eTag = json["eTag"] as? String,
              !eTag.isEmpty else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8) ?? "OneDrive item lookup failed"
            )
        }
        return EmbeddedMetadataRemoteFileState(
            fileSize: int64(json["size"]),
            modifiedDate: (json["lastModifiedDateTime"] as? String).flatMap(parseISO8601),
            revision: contentRevision(from: json) ?? eTag,
            replacementToken: eTag
        )
    }

    private static func contentRevision(from item: [String: Any]) -> String? {
        guard let file = item["file"] as? [String: Any],
              let hashes = file["hashes"] as? [String: Any] else {
            return nil
        }
        return (hashes["sha256Hash"] as? String)
            ?? (hashes["sha1Hash"] as? String)
            ?? (hashes["quickXorHash"] as? String)
    }

    private static func uploadMetadataFile(
        localURL: URL,
        itemID: String,
        expectedETag: String,
        accessToken: String
    ) async throws {
        let totalSize = Int64(
            try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        if totalSize <= 240 * 1024 * 1024 {
            var request = URLRequest(
                url: URL(string: "\(graphBase)/me/drive/items/\(itemID)/content")!
            )
            request.httpMethod = "PUT"
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue(expectedETag, forHTTPHeaderField: "If-Match")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 3_600
            let (data, response) = try await URLSession.shared.upload(
                for: request,
                fromFile: localURL
            )
            _ = try confirmedUploadedItem(data: data, response: response)
            return
        }

        var createRequest = URLRequest(
            url: URL(string: "\(graphBase)/me/drive/items/\(itemID)/createUploadSession")!
        )
        createRequest.httpMethod = "POST"
        createRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        createRequest.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try SafeJSONSerialization.data(withJSONObject: [
            "item": ["@microsoft.graph.conflictBehavior": "replace"],
        ])
        let (sessionData, sessionResponse) = try await URLSession.shared.data(for: createRequest)
        guard let sessionHTTP = sessionResponse as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if sessionHTTP.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if sessionHTTP.statusCode == 409 || sessionHTTP.statusCode == 412 {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        guard (200...299).contains(sessionHTTP.statusCode),
              let sessionJSON = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let uploadURLString = sessionJSON["uploadUrl"] as? String,
              let uploadURL = URL(string: uploadURLString) else {
            throw CloudDriveError.apiError(
                sessionHTTP.statusCode,
                String(data: sessionData.prefix(4_096), encoding: .utf8)
                    ?? "OneDrive upload session creation failed"
            )
        }

        do {
            let handle = try FileHandle(forReadingFrom: localURL)
            defer { try? handle.close() }
            let chunkSize = 10 * 1024 * 1024 // Required multiple of 320 KiB.
            var offset: Int64 = 0
            while offset < totalSize {
                let requested = Int(min(Int64(chunkSize), totalSize - offset))
                let chunk = try handle.read(upToCount: requested) ?? Data()
                guard !chunk.isEmpty else { throw CloudDriveError.invalidResponse }
                let end = offset + Int64(chunk.count) - 1
                let isFinal = end + 1 == totalSize
                if isFinal {
                    let current = try await metadataState(
                        itemID: itemID,
                        accessToken: accessToken
                    )
                    guard current.replacementToken == expectedETag else {
                        throw EmbeddedMetadataWritebackSourceError.conflict
                    }
                }

                var chunkRequest = URLRequest(url: uploadURL)
                chunkRequest.httpMethod = "PUT"
                chunkRequest.setValue(
                    "bytes \(offset)-\(end)/\(totalSize)",
                    forHTTPHeaderField: "Content-Range"
                )
                chunkRequest.setValue(String(chunk.count), forHTTPHeaderField: "Content-Length")
                chunkRequest.timeoutInterval = 600
                let (data, response) = try await URLSession.shared.upload(
                    for: chunkRequest,
                    from: chunk
                )
                guard let http = response as? HTTPURLResponse else {
                    throw CloudDriveError.invalidResponse
                }
                if http.statusCode == 409 || http.statusCode == 412 {
                    throw EmbeddedMetadataWritebackSourceError.conflict
                }
                if isFinal {
                    _ = try confirmedUploadedItem(data: data, response: response)
                } else if http.statusCode != 202 {
                    throw CloudDriveError.apiError(
                        http.statusCode,
                        String(data: data.prefix(4_096), encoding: .utf8)
                            ?? "OneDrive chunk upload failed"
                    )
                }
                offset = end + 1
            }
        } catch {
            var cancelRequest = URLRequest(url: uploadURL)
            cancelRequest.httpMethod = "DELETE"
            _ = try? await URLSession.shared.data(for: cancelRequest)
            throw error
        }
    }

    private static func confirmedUploadedItem(
        data: Data,
        response: URLResponse
    ) throws -> [String: Any] {
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 409 || http.statusCode == 412 {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        guard (200...201).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              !id.isEmpty,
              let eTag = json["eTag"] as? String,
              !eTag.isEmpty else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8)
                    ?? "OneDrive upload was not confirmed"
            )
        }
        return json
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String, let parsed = Int64(value) { return parsed }
        return 0
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let endpoint = (path.isEmpty || path == "/") ? "\(Self.graphBase)/me/drive/root/children" : "\(Self.graphBase)/me/drive/items/\(path)/children"
        var all: [RemoteFileItem] = []
        var nextURL: URL? = {
            var components = URLComponents(string: endpoint)!
            components.queryItems = [
                .init(
                    name: "$select",
                    value: "id,name,folder,file,size,eTag,lastModifiedDateTime,parentReference"
                ),
                .init(name: "$top", value: "999"),
                .init(name: "$orderby", value: "name"),
            ]
            return components.url
        }()
        var seenPageURLs: Set<String> = []
        while let url = nextURL {
            guard CloudPaginationTokenPolicy.canAdvance(
                to: url.absoluteString,
                seenTokens: seenPageURLs
            ) else {
                throw CloudDriveError.invalidResponse
            }
            seenPageURLs.insert(url.absoluteString)
            let token = try await getToken()
            let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(url: url, accessToken: tok)
            }
            if http.statusCode == 404 { throw CloudDriveError.fileNotFound(path) }
            if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["value"] as? [[String: Any]] else {
                throw CloudDriveError.invalidResponse
            }
            all.append(contentsOf: try items.map { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else {
                    throw CloudDriveError.invalidResponse
                }
                // Preserve the hash-based fingerprint used by existing Song
                // rows. The write adapter resolves eTag independently as its
                // conditional replacement token.
                let revision = Self.contentRevision(from: item)
                    ?? (item["eTag"] as? String)
                let parentID = (item["parentReference"] as? [String: Any])?["id"] as? String
                return RemoteFileItem(
                    name: name,
                    path: id,
                    isDirectory: item["folder"] != nil,
                    size: item["size"] as? Int64 ?? 0,
                    modifiedDate: (item["lastModifiedDateTime"] as? String)
                        .flatMap(Self.parseISO8601),
                    revision: revision,
                    providerID: id,
                    // Delta events always report the real driveItem id for the
                    // root parent, not the `/root` URL alias.
                    parentPath: parentID ?? (path.isEmpty || path == "/" ? "root" : path)
                )
            })
            // @odata.nextLink 是完整 URL（已包含 skiptoken）
            if let next = json["@odata.nextLink"] as? String {
                guard !next.isEmpty, let nextU = URL(string: next) else {
                    throw CloudDriveError.invalidResponse
                }
                nextURL = nextU
            } else {
                nextURL = nil
            }
        }
        return all
    }

    func initialChangeCursors(for roots: [String]) async throws -> [String: String] {
        var cursors: [String: String] = [:]
        for root in roots {
            var nextURL = deltaEndpoint(for: root, latestOnly: true)
            var deltaLink: String?
            while let url = nextURL {
                let json = try await getGraphJSON(url)
                if let next = json["@odata.nextLink"] as? String {
                    nextURL = URL(string: next)
                } else {
                    deltaLink = json["@odata.deltaLink"] as? String
                    nextURL = nil
                }
            }
            guard let deltaLink, !deltaLink.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            cursors[root] = deltaLink
        }
        return cursors
    }

    func changes(
        since cursors: [String: String],
        roots: [String],
        index: [String: SourceSyncIndexedItem]
    ) async throws -> IncrementalSourceChanges {
        var committed = cursors
        var changedParents: Set<String> = []
        var deletedKeys: Set<String> = []
        var liveStableKeys: Set<String> = []
        var requiresDeep = false

        for root in roots {
            guard let cursor = cursors[root], var nextURL = URL(string: cursor) else {
                return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
            }
            var finalDelta: String?
            while true {
                let json: [String: Any]
                do {
                    json = try await getGraphJSON(nextURL)
                } catch CloudDriveError.apiError(let code, _) where code == 410 {
                    return IncrementalSourceChanges(cursors: cursors, requiresDeepScan: true)
                }
                for item in json["value"] as? [[String: Any]] ?? [] {
                    guard let id = item["id"] as? String else { continue }
                    let existing = index[id]
                    let parent = (item["parentReference"] as? [String: Any])?["id"] as? String
                    if item["deleted"] != nil {
                        if existing != nil { deletedKeys.insert(id) }
                        if let oldParent = existing?.parentPath { changedParents.insert(oldParent) }
                        continue
                    }
                    deletedKeys.remove(id)
                    liveStableKeys.insert(id)
                    if let oldParent = existing?.parentPath { changedParents.insert(oldParent) }
                    if item["folder"] != nil {
                        requiresDeep = true
                    } else if let parent {
                        changedParents.insert(parent)
                    }
                }
                if let next = json["@odata.nextLink"] as? String,
                   let url = URL(string: next) {
                    nextURL = url
                    continue
                }
                finalDelta = json["@odata.deltaLink"] as? String
                break
            }
            guard let finalDelta, !finalDelta.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            committed[root] = finalDelta
        }
        deletedKeys.subtract(liveStableKeys)
        return IncrementalSourceChanges(
            cursors: committed,
            changedParentPaths: changedParents,
            deletedStableKeys: deletedKeys,
            requiresDeepScan: requiresDeep
        )
    }

    private func deltaEndpoint(for root: String, latestOnly: Bool) -> URL? {
        let base = root.isEmpty || root == "/"
            ? "\(Self.graphBase)/me/drive/root/delta"
            : "\(Self.graphBase)/me/drive/items/\(root)/delta"
        var components = URLComponents(string: base)
        var query: [URLQueryItem] = [
            .init(name: "$select", value: "id,name,folder,file,size,parentReference,deleted,eTag,lastModifiedDateTime"),
        ]
        if latestOnly { query.append(.init(name: "token", value: "latest")) }
        components?.queryItems = query
        return components?.url
    }

    private func getGraphJSON(_ url: URL) async throws -> [String: Any] {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: url, accessToken: tok)
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!, accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Item not found") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["@microsoft.graph.downloadUrl"] as? String, let fileURL = URL(string: downloadUrl) else { throw CloudDriveError.fileNotFound(path) }
        return try await helper.downloadToCache(request: URLRequest(url: fileURL), for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let token = try await getToken()
        return try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            try await Self.metadataState(itemID: path, accessToken: accessToken)
        }
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard let eTag = expected.replacementToken, !eTag.isEmpty else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let token = try await getToken()
        try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            try await Self.uploadMetadataFile(
                localURL: localURL,
                itemID: path,
                expectedETag: eTag,
                accessToken: accessToken
            )
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        invalidateDownloadURL(for: path)
        helper.invalidateCachedFile(path: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    /// Microsoft Graph DELETE moves a driveItem to OneDrive's recycle bin.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty else { throw CloudDriveError.invalidResponse }
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!,
                method: "DELETE", accessToken: tok
            )
        }
        guard http.statusCode == 204 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        invalidateDownloadURL(for: path)
        plog("🗑️ OneDrive item moved to recycle bin: \(path)")
    }

    /// Microsoft 推荐第三方流量带「装饰」User-Agent(格式 NONISV|公司|应用/版本),
    /// 否则 undecorated 流量在 SharePoint/OneDrive CDN 可能被降级调度。URLSession
    /// 跨 302 保留自定义 header, 所以重定向到 *.microsoftpersonalcontent.com CDN 后仍生效。
    private static let rangeUserAgent = "NONISV|Welape|Primuse/1.6.0"

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        // OneDrive returns a short-lived pre-authenticated downloadUrl per
        // item. Range requests against that URL don't need our Bearer token.
        // Cache it for ~50min (Microsoft documents 1h validity, leave margin).
        let fileURL = try await getDownloadURL(for: path)
        do {
            return try await helper.rangeRequest(url: fileURL, offset: offset, length: length, userAgent: Self.rangeUserAgent, forceTCP: true)
        } catch CloudDriveError.apiError(let code, _) where code == 401 || code == 403 || code == 410 {
            // URL expired between cache and use — invalidate and retry once.
            invalidateDownloadURL(for: path)
            let fresh = try await getDownloadURL(for: path)
            return try await helper.rangeRequest(url: fresh, offset: offset, length: length, userAgent: Self.rangeUserAgent, forceTCP: true)
        }
    }

    /// 暴露预授权下载直链,供大文件「整文件渐进下载」绕开逐 chunk Range。
    /// OneDrive 服务端对大文件的分段 Range 会挂死(冷文件 hydration),但整文件直接
    /// 下载很快 —— 大文件改走 StreamingDownloadDecoder 一次性渐进下载。
    func publicDownloadURL(path: String, forceRefresh: Bool = false) async throws -> URL {
        if forceRefresh {
            invalidateDownloadURL(for: path)
        }
        return try await getDownloadURL(for: path)
    }

    func invalidateCachedDownloadURL(path: String) {
        invalidateDownloadURL(for: path)
        plog("☁️ OneDrive downloadUrl invalidated for item=\(path.prefix(24))…")
    }

    func displayName(for path: String) async throws -> String? {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)?$select=name")!,
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, "OneDrive item name lookup")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["name"] as? String
    }

    /// 把刮削的 sidecar(歌词 .lrc / 封面 -cover.jpg)上传回 OneDrive,放源歌曲同目录、
    /// 用歌曲真实文件名命名(重新扫描时 findSameName* 能按同名读回,从而多设备共享)。
    /// `path` 由 SidecarWriteService 用 song.filePath(OneDrive 是 item ID)拼成,形如
    /// "{itemID}-cover.jpg" / "{itemID}.lrc"。这里反解出源 item → 查真实文件名+父目录 → 上传。
    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if path.hasSuffix(".lrc") { suffix = ".lrc" }
        else { throw CloudDriveError.invalidResponse }
        let itemID = String(path.dropLast(suffix.count))
        guard !itemID.isEmpty else { throw CloudDriveError.invalidResponse }

        let token = try await getToken()
        // Wrap the metadata lookup + content PUT so a server-side early token
        // revocation (401) triggers one force-refresh + retry of the whole
        // sidecar write rather than failing until local expiry.
        let (sidecarName, sidecarID): (String, String) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            let (metaData, metaHTTP) = try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.graphBase)/me/drive/items/\(itemID)?$select=name,parentReference")!,
                accessToken: tok)
            guard metaHTTP.statusCode == 200 else { throw CloudDriveError.apiError(metaHTTP.statusCode, "item lookup") }
            let json = (try? JSONSerialization.jsonObject(with: metaData)) as? [String: Any] ?? [:]
            guard let name = json["name"] as? String,
                  let parentID = (json["parentReference"] as? [String: Any])?["id"] as? String else {
                throw CloudDriveError.invalidResponse
            }
            let sidecarName = (name as NSString).deletingPathExtension + suffix
            let encoded = sidecarName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? sidecarName
            let uploadURL = URL(string: "\(Self.graphBase)/me/drive/items/\(parentID):/\(encoded):/content")!
            var req = URLRequest(url: uploadURL)
            req.httpMethod = "PUT"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue(suffix == ".lrc" ? "text/plain; charset=utf-8" : "image/jpeg", forHTTPHeaderField: "Content-Type")
            let (responseData, resp) = try await URLSession.shared.upload(for: req, from: data)
            guard let http = resp as? HTTPURLResponse else {
                throw CloudDriveError.invalidResponse
            }
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            guard (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(http.statusCode, "sidecar upload failed")
            }
            guard let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                  let uploadedID = responseJSON["id"] as? String,
                  !uploadedID.isEmpty,
                  Self.int64(responseJSON["size"]) == Int64(data.count) else {
                throw CloudDriveError.invalidResponse
            }
            return (sidecarName, uploadedID)
        }
        await invalidateMetadataWritebackCache(for: sidecarID)
        let readback = try await fetchRange(
            path: sidecarID,
            offset: 0,
            length: Int64(data.count)
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        plog("📁 OneDrive sidecar uploaded and verified: \(sidecarName)")
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        // `writeFile` reads the returned driveItem id back byte-for-byte.
    }

    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    /// Microsoft documents `@microsoft.graph.downloadUrl` as valid for ~1
    /// hour. Use 50min to leave a safety margin against clock skew.
    private static let downloadURLTTL: TimeInterval = 50 * 60

    private func getDownloadURL(for path: String) async throws -> URL {
        if let cached = downloadURLCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.graphBase)/me/drive/items/\(path)")!, accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Item not found") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["@microsoft.graph.downloadUrl"] as? String,
              let fileURL = URL(string: downloadUrl) else {
            throw CloudDriveError.fileNotFound(path)
        }
        downloadURLCache[path] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
        return fileURL
    }

    private func invalidateDownloadURL(for path: String) {
        downloadURLCache.removeValue(forKey: path)
    }

    private func getToken() async throws -> String {
        // proactive 路径: 本地标记过期才刷新, 与 reactive(401)路径共享 CloudTokenManager
        // 里的同一个 in-flight 去重任务, 避免轮换型 refresh_token 被并发刷新作废。
        try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    // nonisolated: 只用 helper(Sendable)/静态常量/URLSession, 不碰可变 actor 状态,
    // 这样能作为 @Sendable 闭包传给 tokenManager.refreshDeduped / withTokenRetry。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = try await helper.tokenManager.requireAppCredentials()
        guard !creds.clientId.isEmpty else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var request = URLRequest(url: URL(string: "\(Self.authBase)/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudDriveHelper.formURLEncodedBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
            URLQueryItem(name: "client_id", value: creds.clientId),
            URLQueryItem(name: "scope", value: "Files.ReadWrite offline_access"),
        ])
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        guard let at = json["access_token"] as? String else {
            throw CloudDriveHelper.tokenRefreshFailure(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600))
    }

    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .oneDrive,
            authURL: "\(authBase)/authorize",
            tokenURL: "\(authBase)/token",
            clientId: clientId,
            clientSecret: nil,
            scopes: ["Files.ReadWrite", "offline_access"],
            redirectURI: redirectURI()
        )
    }

    private static func redirectURI() -> String {
        guard let bundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !bundleID.isEmpty else {
            return fallbackRedirectURI
        }
        return "msauth.\(bundleID)://auth"
    }
}
