import CryptoKit
import Foundation
import PrimuseKit

/// 阿里云盘 Source — PDS API
actor AliyunDriveSource: MusicSourceConnector, OAuthCloudSource,
    RemoteFileDisplayNameProviding, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削歌词/封面写回阿里云盘同目录
    private let helper: CloudDriveHelper
    private var driveId: String?

    /// 写 sidecar 到阿里云盘。已有同名文件时沿用原 file_id 覆盖内容；新文件
    /// 才走 create。两条路径都校验最终 size/SHA-1，不能把 `exist=true` 当成
    /// “新内容已写入”。
    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if path.hasSuffix(".lrc") { suffix = ".lrc" }
        else { throw CloudDriveError.invalidResponse }
        let fileID = String(path.dropLast(suffix.count))
        guard !fileID.isEmpty else { throw CloudDriveError.invalidResponse }

        let token = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] { driveId = id }
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }

        let localURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse-aliyun-sidecar-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: localURL) }
        try data.write(to: localURL, options: .atomic)
        let descriptor = try Self.uploadDescriptor(localURL: localURL)

        // 整段写流程套 withTokenRetry:服务端提前失效 token(401)时一次性强制刷新 +
        // 重跑(get → create → 可选 PUT → complete),而不是等本地 expiresAt 过期。
        let writtenFileID: String = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            let source = try await Self.metadataDetail(
                driveID: driveId,
                fileID: fileID,
                accessToken: tok
            )
            let sidecarName = (source.name as NSString).deletingPathExtension + suffix

            if let existingID = try await Self.existingFileID(
                driveID: driveId,
                parentFileID: source.parentFileID,
                name: sidecarName,
                accessToken: tok
            ) {
                let existing = try await Self.metadataDetail(
                    driveID: driveId,
                    fileID: existingID,
                    accessToken: tok
                )
                try await Self.uploadReplacement(
                    localURL: localURL,
                    descriptor: descriptor,
                    detail: existing,
                    driveID: driveId,
                    expected: existing.state,
                    accessToken: tok
                )
                try await Self.verifyUploadedFile(
                    driveID: driveId,
                    fileID: existingID,
                    descriptor: descriptor,
                    accessToken: tok
                )
                return existingID
            }

            let proof = try Self.proofCode(
                token: tok,
                localURL: localURL,
                size: descriptor.size
            )
            let createBody = try SafeJSONSerialization.data(withJSONObject: [
                "drive_id": driveId,
                "parent_file_id": source.parentFileID,
                "name": sidecarName,
                "type": "file",
                "check_name_mode": "refuse",
                "size": descriptor.size,
                "content_hash_name": "sha1",
                "content_hash": descriptor.sha1,
                "proof_version": "v1",
                "proof_code": proof,
                "part_info_list": [["part_number": 1]],
            ])
            let created = try await Self.authorizedJSONRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/create")!,
                body: createBody,
                accessToken: tok,
                operation: "create sidecar upload"
            )
            if created["exist"] as? Bool == true {
                // Another client created the name after our listing. Retrying
                // will take the guarded existing-file branch.
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            guard let newFileID = created["file_id"] as? String, !newFileID.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            let rapid = created["rapid_upload"] as? Bool ?? false

            if !rapid {
                guard let uploadID = created["upload_id"] as? String,
                      !uploadID.isEmpty,
                      let uploadURL = (created["part_info_list"] as? [[String: Any]])?
                        .first?["upload_url"] as? String,
                      let put = URL(string: uploadURL) else {
                    throw CloudDriveError.invalidResponse
                }
                var putReq = URLRequest(url: put)
                putReq.httpMethod = "PUT"
                let (_, pResp) = try await URLSession.shared.upload(for: putReq, from: data)
                guard let ph = pResp as? HTTPURLResponse, (200...299).contains(ph.statusCode) else {
                    throw CloudDriveError.apiError((pResp as? HTTPURLResponse)?.statusCode ?? 0, "aliyun part PUT")
                }
                let completeBody = try SafeJSONSerialization.data(withJSONObject: [
                    "drive_id": driveId,
                    "file_id": newFileID,
                    "upload_id": uploadID,
                ])
                let completed = try await Self.authorizedJSONRequest(
                    url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/complete")!,
                    body: completeBody,
                    accessToken: tok,
                    operation: "complete sidecar upload"
                )
                guard completed["file_id"] as? String == newFileID else {
                    throw CloudDriveError.invalidResponse
                }
            }
            try await Self.verifyUploadedFile(
                driveID: driveId,
                fileID: newFileID,
                descriptor: descriptor,
                accessToken: tok
            )
            return newFileID
        }
        await invalidateMetadataWritebackCache(for: writtenFileID)
        plog("📁 Aliyun sidecar uploaded and verified")
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        // `writeFile` verifies the provider file_id's final size and SHA-1.
    }

    private struct MetadataDetail: Sendable {
        let state: EmbeddedMetadataRemoteFileState
        let name: String
        let parentFileID: String
        let fileID: String
    }

    private static func existingFileID(
        driveID: String,
        parentFileID: String,
        name: String,
        accessToken: String
    ) async throws -> String? {
        var marker: String?
        var seenMarkers: Set<String> = []
        repeat {
            var object: [String: Any] = [
                "drive_id": driveID,
                "parent_file_id": parentFileID,
                "limit": 200,
            ]
            if let marker, !marker.isEmpty { object["marker"] = marker }
            let body = try SafeJSONSerialization.data(withJSONObject: object)
            let response = try await authorizedJSONRequest(
                url: URL(string: "\(apiBase)/adrive/v1.0/openFile/list")!,
                body: body,
                accessToken: accessToken,
                operation: "list sidecars"
            )
            guard let items = response["items"] as? [[String: Any]] else {
                throw CloudDriveError.invalidResponse
            }
            if let item = items.first(where: {
                $0["type"] as? String == "file" && $0["name"] as? String == name
            }), let fileID = item["file_id"] as? String, !fileID.isEmpty {
                return fileID
            }
            marker = response["next_marker"] as? String
            if let marker, !marker.isEmpty,
               !seenMarkers.insert(marker).inserted {
                throw CloudDriveError.invalidResponse
            }
        } while marker?.isEmpty == false
        return nil
    }

    private static func verifyUploadedFile(
        driveID: String,
        fileID: String,
        descriptor: UploadDescriptor,
        accessToken: String
    ) async throws {
        let final = try await metadataDetail(
            driveID: driveID,
            fileID: fileID,
            accessToken: accessToken
        )
        guard final.state.fileSize == descriptor.size,
              final.state.revision?.caseInsensitiveCompare(descriptor.sha1) == .orderedSame else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
    }

    private struct UploadDescriptor: Sendable {
        let size: Int64
        let sha1: String
        let partSize: Int
        let partCount: Int
    }

    private static func metadataDetail(
        driveID: String,
        fileID: String,
        accessToken: String
    ) async throws -> MetadataDetail {
        let body = try SafeJSONSerialization.data(withJSONObject: [
            "drive_id": driveID,
            "file_id": fileID,
        ])
        var request = URLRequest(
            url: URL(string: "\(apiBase)/adrive/v1.0/openFile/get")!
        )
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 404 { throw CloudDriveError.fileNotFound(fileID) }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == "file",
              let returnedID = json["file_id"] as? String,
              returnedID == fileID,
              let name = json["name"] as? String,
              let parentFileID = json["parent_file_id"] as? String,
              let hash = (json["content_hash"] as? String)?.uppercased(),
              !hash.isEmpty else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8)
                    ?? "Aliyun Drive file lookup failed"
            )
        }
        return MetadataDetail(
            state: EmbeddedMetadataRemoteFileState(
                fileSize: int64(json["size"]),
                modifiedDate: (json["updated_at"] as? String).flatMap(parseISO8601),
                revision: hash
            ),
            name: name,
            parentFileID: parentFileID,
            fileID: returnedID
        )
    }

    private static func uploadDescriptor(localURL: URL) throws -> UploadDescriptor {
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        var digest = Insecure.SHA1()
        var size: Int64 = 0
        while true {
            let chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if chunk.isEmpty { break }
            digest.update(data: chunk)
            size += Int64(chunk.count)
        }
        guard size > 0 else { throw CloudDriveError.invalidResponse }
        let partSize = 10 * 1024 * 1024
        let partCount = Int((size + Int64(partSize) - 1) / Int64(partSize))
        guard partCount <= 10_000 else {
            throw CloudDriveError.apiError(0, "Aliyun upload exceeds the supported part count")
        }
        return UploadDescriptor(
            size: size,
            sha1: digest.finalize().map { String(format: "%02X", $0) }.joined(),
            partSize: partSize,
            partCount: partCount
        )
    }

    private static func uploadReplacement(
        localURL: URL,
        descriptor: UploadDescriptor,
        detail: MetadataDetail,
        driveID: String,
        expected: EmbeddedMetadataRemoteFileState,
        accessToken: String
    ) async throws {
        let proof = try proofCode(
            token: accessToken,
            localURL: localURL,
            size: descriptor.size
        )
        let partInfo = (1...descriptor.partCount).map { ["part_number": $0] }
        let createBody = try SafeJSONSerialization.data(withJSONObject: [
            "drive_id": driveID,
            "file_id": detail.fileID,
            "parent_file_id": detail.parentFileID,
            "name": detail.name,
            "type": "file",
            "size": descriptor.size,
            "content_hash_name": "sha1",
            "content_hash": descriptor.sha1,
            "proof_version": "v1",
            "proof_code": proof,
            "part_info_list": partInfo,
        ])
        let create = try await authorizedJSONRequest(
            url: URL(string: "\(apiBase)/adrive/v1.0/openFile/create")!,
            body: createBody,
            accessToken: accessToken,
            operation: "create replacement upload"
        )
        guard create["file_id"] as? String == detail.fileID else {
            throw CloudDriveError.invalidResponse
        }
        if create["rapid_upload"] as? Bool == true {
            return
        }
        guard let uploadID = create["upload_id"] as? String,
              !uploadID.isEmpty,
              let returnedParts = create["part_info_list"] as? [[String: Any]],
              returnedParts.count == descriptor.partCount else {
            throw CloudDriveError.invalidResponse
        }
        let uploadURLs: [Int: URL] = try Dictionary(
            uniqueKeysWithValues: returnedParts.map { part in
                guard let number = optionalInt(part["part_number"]),
                      let value = part["upload_url"] as? String,
                      let url = URL(string: value) else {
                    throw CloudDriveError.invalidResponse
                }
                return (number, url)
            }
        )

        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        for partNumber in 1...descriptor.partCount {
            guard let uploadURL = uploadURLs[partNumber] else {
                throw CloudDriveError.invalidResponse
            }
            let chunk = try handle.read(upToCount: descriptor.partSize) ?? Data()
            guard !chunk.isEmpty else { throw CloudDriveError.invalidResponse }
            var request = URLRequest(url: uploadURL)
            request.httpMethod = "PUT"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 600
            let (data, response) = try await URLSession.shared.upload(for: request, from: chunk)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                throw CloudDriveError.apiError(
                    (response as? HTTPURLResponse)?.statusCode ?? 0,
                    String(data: data.prefix(4_096), encoding: .utf8)
                        ?? "Aliyun part upload failed"
                )
            }
        }

        let current = try await metadataDetail(
            driveID: driveID,
            fileID: detail.fileID,
            accessToken: accessToken
        )
        guard expected.matches(current.state) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        let completeBody = try SafeJSONSerialization.data(withJSONObject: [
            "drive_id": driveID,
            "file_id": detail.fileID,
            "upload_id": uploadID,
        ])
        let completed = try await authorizedJSONRequest(
            url: URL(string: "\(apiBase)/adrive/v1.0/openFile/complete")!,
            body: completeBody,
            accessToken: accessToken,
            operation: "complete replacement upload"
        )
        guard completed["file_id"] as? String == detail.fileID else {
            throw CloudDriveError.invalidResponse
        }
        if let size = optionalInt64(completed["size"]), size != descriptor.size {
            throw CloudDriveError.invalidResponse
        }
        if let hash = (completed["content_hash"] as? String)?.uppercased(),
           hash != descriptor.sha1 {
            throw CloudDriveError.invalidResponse
        }
    }

    private static func authorizedJSONRequest(
        url: URL,
        body: Data,
        accessToken: String,
        operation: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 409 || http.statusCode == 412 {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        guard (200...201).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8) ?? "Aliyun \(operation) failed"
            )
        }
        if let code = json["code"] as? String, !code.isEmpty {
            throw CloudDriveError.apiError(
                http.statusCode,
                "\(code): \(json["message"] as? String ?? operation)"
            )
        }
        return json
    }

    private static func proofCode(
        token: String,
        localURL: URL,
        size: Int64
    ) throws -> String {
        let md5 = Insecure.MD5.hash(data: Data(token.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        guard size > 0, let value = UInt64(md5.prefix(16), radix: 16) else { return "" }
        let offset = value % UInt64(size)
        let handle = try FileHandle(forReadingFrom: localURL)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return (try handle.read(upToCount: 8) ?? Data()).base64EncodedString()
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func optionalInt(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func optionalInt64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    private static func int64(_ value: Any?) -> Int64 {
        optionalInt64(value) ?? 0
    }
    /// path → (downloadURL, expiry). Aliyun signed URLs are good for ~4
    /// hours; we cache for 30min to skip the getDownloadUrl round-trip on
    /// every range fetch within a single play session.
    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 30 * 60
    private static let apiBase = "https://openapi.alipan.com"
    private static let oauthBase = "https://openapi.alipan.com/oauth"

    init(sourceID: String) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
    }

    func connect() async throws {
        _ = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] { driveId = id }
            else { driveId = try await fetchDriveId() }
        }
    }

    func disconnect() async {}

    /// Aliyun's OIDC `oauth/users/info` endpoint — returns the OAuth
    /// account UID independent of which drive the user picks. Stable
    /// across token refresh and across devices.
    func accountIdentifier() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.oauthBase)/users/info")!,
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // Aliyun returns `id`; `sub` is provided when the response is
        // a true OIDC token. Accept either to ride out provider drift.
        if let id = json["id"] as? String, !id.isEmpty { return id }
        if let sub = json["sub"] as? String, !sub.isEmpty { return sub }
        plog("⚠️ Aliyun accountIdentifier: missing id/sub in response: \(json)")
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let parentFileId = path.isEmpty || path == "/" ? "root" : path
        var all: [RemoteFileItem] = []
        var marker: String? = nil
        var seenMarkers: Set<String> = []
        repeat {
            var body: [String: Any] = ["drive_id": driveId, "parent_file_id": parentFileId, "limit": 200, "order_by": "name", "order_direction": "ASC"]
            if let m = marker, !m.isEmpty { body["marker"] = m }
            let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
            let token = try await getToken()
            let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
                try await self.helper.makeAuthorizedRequest(
                    url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/list")!,
                    method: "POST",
                    body: bodyData,
                    contentType: "application/json",
                    accessToken: tok,
                    isIdempotent: true
                )
            }
            if http.statusCode == 404 { throw CloudDriveError.fileNotFound(parentFileId) }
            if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let items = json["items"] as? [[String: Any]] else {
                throw CloudDriveError.invalidResponse
            }
            all.append(contentsOf: try items.map { item in
                guard let name = item["name"] as? String,
                      let fileId = item["file_id"] as? String,
                      let type = item["type"] as? String else {
                    throw CloudDriveError.invalidResponse
                }
                // Aliyun returns content_hash (sha1 by default) for files;
                // use it as the revision so re-scan catches same-size,
                // same-mtime overwrites.
                let hash = (item["content_hash"] as? String)?.uppercased()
                return RemoteFileItem(
                    name: name,
                    path: fileId,
                    isDirectory: type == "folder",
                    size: Self.int64(item["size"]),
                    modifiedDate: (item["updated_at"] as? String).flatMap(Self.parseISO8601),
                    revision: hash,
                    providerID: fileId,
                    parentPath: parentFileId
                )
            })
            if let next = json["next_marker"] as? String, !next.isEmpty {
                guard CloudPaginationTokenPolicy.canAdvance(
                    to: next,
                    seenTokens: seenMarkers
                ) else {
                    throw CloudDriveError.invalidResponse
                }
                seenMarkers.insert(next)
                marker = next
            } else {
                marker = nil
            }
        } while marker != nil
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        return try await helper.downloadToCache(request: URLRequest(url: url), for: path)
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let token = try await getToken()
        return try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            try await Self.metadataDetail(
                driveID: driveId,
                fileID: path,
                accessToken: accessToken
            ).state
        }
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        guard expected.revision?.isEmpty == false else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let descriptor = try Self.uploadDescriptor(localURL: localURL)
        let token = try await getToken()
        try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            let current = try await Self.metadataDetail(
                driveID: driveId,
                fileID: path,
                accessToken: accessToken
            )
            guard expected.matches(current.state) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            try await Self.uploadReplacement(
                localURL: localURL,
                descriptor: descriptor,
                detail: current,
                driveID: driveId,
                expected: expected,
                accessToken: accessToken
            )
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        downloadURLCache.removeValue(forKey: path)
        helper.invalidateCachedFile(path: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func displayName(for path: String) async throws -> String? {
        let token = try await getToken()
        if driveId == nil {
            if let tokens = await helper.tokenManager.getTokens(), let id = tokens.extra?["drive_id"] {
                driveId = id
            } else {
                driveId = try await fetchDriveId()
            }
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let body = try SafeJSONSerialization.data(withJSONObject: ["drive_id": driveId, "file_id": path])
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/get")!,
                method: "POST",
                body: body,
                contentType: "application/json",
                accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, "Aliyun file name lookup")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["name"] as? String
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    /// Move the item to Aliyun Drive's recycle bin. PDS may report failures
    /// in a JSON body, so a 2xx status alone is not treated as confirmation.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty, let driveId else { throw CloudDriveError.invalidResponse }
        let token = try await getToken()
        let body = try SafeJSONSerialization.data(withJSONObject: [
            "drive_id": driveId,
            "file_id": path,
        ])
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/recyclebin/trash")!,
                method: "POST",
                body: body,
                contentType: "application/json",
                accessToken: tok
            )
        }
        guard (200...299).contains(http.statusCode) else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let code = json["code"] as? String, !code.isEmpty {
            throw CloudDriveError.apiError(http.statusCode, "\(code): \(json["message"] as? String ?? "")")
        }
        downloadURLCache.removeValue(forKey: path)
        plog("🗑️ Aliyun Drive item moved to recycle bin: \(path)")
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    private func getDownloadURL(for path: String) async throws -> URL {
        if let cached = downloadURLCache[path], cached.expiresAt > Date() {
            return cached.url
        }
        guard let driveId else { throw CloudDriveError.notAuthenticated }
        let token = try await getToken()
        let body: [String: Any] = ["drive_id": driveId, "file_id": path]
        let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/openFile/getDownloadUrl")!, method: "POST", body: bodyData, contentType: "application/json", accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard let downloadUrl = json["url"] as? String, let fileURL = URL(string: downloadUrl) else {
            throw CloudDriveError.fileNotFound(path)
        }
        downloadURLCache[path] = (fileURL, Date().addingTimeInterval(Self.downloadURLTTL))
        return fileURL
    }

    private func fetchDriveId() async throws -> String {
        let token = try await getToken()
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: URL(string: "\(Self.apiBase)/adrive/v1.0/user/getDriveInfo")!, method: "POST", body: Data("{}".utf8), contentType: "application/json", accessToken: tok)
        }
        guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, "Failed to get drive info") }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let id = json["resource_drive_id"] as? String, !id.isEmpty { return id }
        guard let id = json["default_drive_id"] as? String else { throw CloudDriveError.invalidResponse }
        return id
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
        let body: [String: String] = ["grant_type": "refresh_token", "refresh_token": rt, "client_id": creds.clientId, "client_secret": creds.clientSecret ?? ""]
        let bodyData = try SafeJSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: URL(string: "\(Self.oauthBase)/access_token")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = bodyData
        let (data, response) = try await URLSession.shared.data(for: request)
        let json = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        guard let at = json["access_token"] as? String else {
            throw CloudDriveHelper.tokenRefreshFailure(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        return .init(accessToken: at, refreshToken: json["refresh_token"] as? String ?? rt, expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 7200), extra: tokens.extra)
    }

    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(provider: .aliyunDrive, authURL: "\(oauthBase)/authorize", tokenURL: "\(oauthBase)/access_token", clientId: clientId, clientSecret: clientSecret, scopes: ["user:base", "file:all:read", "file:all:write"], redirectURI: "\(CloudOAuthConfig.callbackScheme)://aliyun/callback")
    }
}
