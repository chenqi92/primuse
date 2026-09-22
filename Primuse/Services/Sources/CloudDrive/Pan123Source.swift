import CryptoKit
import Foundation
import PrimuseKit

/// 123 云盘 Source — 123 开放平台 OpenAPI(open-api.123pan.com),第三方挂载应用 OAuth 模式。
///
/// 用户在 App 内通过标准 OAuth 授权码流程授权自己的 123 账号:
///   1. 跳 https://yun.123pan.com/auth(内置 appId 作 client_id, scope 固定
///      `user:base,file:all:read,file:all:write`)
///   2. 用户授权后直接回调已登记的 `primuse://oauth/123pan/callback`
///   3. POST /api/v1/oauth2/access_token 用 code 换 access_token + refresh_token(90 天)
/// 之后所有 API 带头 `Platform: open_platform` + `Authorization: Bearer <token>`,
/// 响应统一 `{code:0, message, data}`(code==0 成功; 401 token 失效; 429 限流)。
///
/// 刮削的封面 / 歌词通过 V2 单步上传(/upload/v2/file/single/create)回写到源歌曲
/// 同目录(用源文件真实名 + `-cover.jpg` / `.lrc`),重扫时按同名读回,多设备共享。
///
/// 123 用「文件 ID」而非层级路径标识文件 —— `RemoteFileItem.path` / `Song.filePath`
/// 存的是 fileId 字符串。sidecar 写入时 SidecarWriteService 传来的 path 形如
/// `"{fileId}-cover.jpg"`,这里反解 fileId → 查文件详情拿真实名 + 父目录 → 上传。
actor Pan123Source: MusicSourceConnector, OAuthCloudSource, LyricsSidecarTargetResolving, EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削封面/歌词回写 123 云盘
    nonisolated let preferredDeleteBatchSize = 100
    private let helper: CloudDriveHelper
    private let session: URLSession
    private let tokenProvider: (@Sendable () async throws -> String)?

    private static let apiBase = "https://open-api.123pan.com"
    private static let authURL = "https://yun.123pan.com/auth"
    private static let tokenURL = "\(apiBase)/api/v1/oauth2/access_token"
    /// 单步上传的兜底域名 —— 正常应走 /upload/v2/file/domain 动态获取,失败时用这个。
    private static let fallbackUploadDomain = "https://openapi-upload.123pan.com"
    static let redirectURI = "\(CloudOAuthConfig.callbackScheme)://oauth/123pan/callback"

    private var downloadURLCache: [String: (url: URL, expiresAt: Date)] = [:]
    private static let downloadURLTTL: TimeInterval = 20 * 60
    private var cachedUploadDomain: (value: String, expiresAt: Date)?
    private static let uploadDomainTTL: TimeInterval = 30 * 60
    /// 分片上传 `upload_complete` 的轮询上限与间隔(见 replaceMetadataFileReturningPath)。
    private let uploadCompletionPollLimit: Int
    private let uploadCompletionPollInterval: Duration

    init(
        sourceID: String,
        session: URLSession = .shared,
        tokenProvider: (@Sendable () async throws -> String)? = nil,
        uploadCompletionPollLimit: Int = 60,
        uploadCompletionPollInterval: Duration = .seconds(1)
    ) {
        self.sourceID = sourceID
        self.helper = CloudDriveHelper(sourceID: sourceID)
        self.session = session
        self.tokenProvider = tokenProvider
        self.uploadCompletionPollLimit = max(1, uploadCompletionPollLimit)
        self.uploadCompletionPollInterval = uploadCompletionPollInterval
    }

    func connect() async throws { _ = try await getToken() }
    func disconnect() async {}

    /// 123 `/api/v1/user/info` 返回 `data.uid` —— 跨刷新 / 跨设备稳定的账号标识。
    func accountIdentifier() async throws -> String {
        let json = try await authedRequest("/api/v1/user/info")
        let data = json["data"] as? [String: Any] ?? [:]
        if let uid = Self.intValue(data["uid"]) { return String(uid) }
        if let uid = data["uid"] as? String, !uid.isEmpty { return uid }
        throw CloudDriveError.invalidResponse
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        let parent = path.isEmpty || path == "/" ? "0" : path
        var all: [RemoteFileItem] = []
        var lastFileId: String? = nil
        var seenLastFileIDs: Set<String> = []
        while true {
            var query = "/api/v2/file/list?parentFileId=\(parent)&limit=100"
            if let l = lastFileId { query += "&lastFileId=\(l)" }
            let json = try await authedRequest(query)
            guard let data = json["data"] as? [String: Any],
                  let list = data["fileList"] as? [[String: Any]],
                  let lastValue = data["lastFileId"] else {
                throw CloudDriveError.invalidResponse
            }
            for item in list {
                guard let name = item["filename"] as? String, let fid = item["fileId"] else {
                    throw CloudDriveError.invalidResponse
                }
                if (Self.intValue(item["trashed"]) ?? 0) != 0 { continue }   // 跳过回收站文件
                let isDir = Self.intValue(item["type"]) == 1
                let size = (item["size"] as? Int64) ?? Int64(Self.intValue(item["size"]) ?? 0)
                let etag = item["etag"] as? String
                let fileID = Self.idString(fid)
                all.append(RemoteFileItem(
                    name: name,
                    path: fileID,
                    isDirectory: isDir,
                    size: isDir ? 0 : size,
                    modifiedDate: nil,
                    revision: etag,
                    providerID: fileID,
                    parentPath: parent
                ))
            }
            // 123 分页:data.lastFileId == -1 表示到底。
            let next = Self.idString(lastValue)
            if next == "-1" { break }
            guard CloudPaginationTokenPolicy.canAdvance(
                to: next,
                seenTokens: seenLastFileIDs
            ) else {
                throw CloudDriveError.invalidResponse
            }
            seenLastFileIDs.insert(next)
            lastFileId = next
        }
        return all
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let url = try await getDownloadURL(for: path)
        return try await helper.downloadToCache(request: URLRequest(url: url), for: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let url = try await getDownloadURL(for: path)
        return try await helper.rangeRequest(url: url, offset: offset, length: length)
    }

    // MARK: - Embedded metadata replacement

    private struct MetadataFile {
        let name: String
        let parentID: Int
        let state: EmbeddedMetadataRemoteFileState
    }

    private func metadataFile(for path: String) async throws -> MetadataFile {
        guard let fileID = Int(path), fileID > 0 else {
            throw CloudDriveError.invalidResponse
        }
        let json = try await authedRequest("/api/v1/file/detail?fileID=\(fileID)")
        guard let data = json["data"] as? [String: Any],
              Self.intValue(data["fileID"] ?? data["fileId"]) == fileID,
              Self.intValue(data["type"]) == 0,
              Self.intValue(data["trashed"]) == 0,
              let name = data["filename"] as? String, !name.isEmpty,
              let parent = Self.intValue(data["parentFileID"]), parent >= 0,
              let size = Self.intValue(data["size"]), size > 0,
              let md5 = data["etag"] as? String,
              md5.count == 32, md5.allSatisfy({ $0.isHexDigit }) else {
            throw CloudDriveError.invalidResponse
        }
        return MetadataFile(
            name: name,
            parentID: parent,
            state: EmbeddedMetadataRemoteFileState(
                fileSize: Int64(size), modifiedDate: nil, revision: md5.lowercased(),
                replacementToken: "\(parent)/\(name)"
            )
        )
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        try await metadataFile(for: path).state
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        invalidateDownloadURL(for: path)
        helper.invalidateCachedFile(path: path)
    }

    func replaceMetadataFile(
        at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        _ = try await replaceMetadataFileReturningPath(at: path, with: localURL, expected: expected)
    }

    private func unchangedMetadataFile(
        at path: String, expected: EmbeddedMetadataRemoteFileState
    ) async throws -> MetadataFile {
        let file = try await metadataFile(for: path)
        guard expected.matches(file.state) else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        // duplicate=2 replaces by name, so an ambiguous same-name sibling must
        // never be allowed to turn a tag edit into replacement of another file.
        let matches = try await listFiles(at: String(file.parentID)).filter { $0.name == file.name }
        guard matches.count == 1, matches.first?.path == path else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        return file
    }

    func replaceMetadataFileReturningPath(
        at path: String, with localURL: URL, expected: EmbeddedMetadataRemoteFileState
    ) async throws -> String {
        guard expected.revision?.isEmpty == false else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let size = Int64(try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0, size <= 10 * 1024 * 1024 * 1024 else {
            throw CloudDriveError.invalidResponse
        }
        let md5 = try await Task.detached(priority: .utility) {
            try Self.metadataMD5(at: localURL)
        }.value
        let original = try await unchangedMetadataFile(at: path, expected: expected)
        let createBody = try JSONSerialization.data(withJSONObject: [
            "parentFileID": original.parentID, "filename": original.name,
            "etag": md5, "size": size, "duplicate": 2, "containDir": false,
        ])
        let replacementPath: String
        do {
            let json = try await authedRequest("/upload/v2/file/create", method: "POST", body: createBody)
            guard let data = json["data"] as? [String: Any] else { throw CloudDriveError.invalidResponse }
            if Self.intValue(data["reuse"]) == 1 {
                replacementPath = try Self.uploadedFileID(data)
            } else {
                guard Self.intValue(data["reuse"]) == 0,
                      let uploadID = data["preuploadID"] as? String, !uploadID.isEmpty,
                      let sliceSize = Self.intValue(data["sliceSize"]), sliceSize > 0,
                      let servers = data["servers"] as? [String],
                      let server = servers.first,
                      let endpoint = URL(string: server)?.appendingPathComponent("upload/v2/file/slice"),
                      endpoint.scheme == "https", endpoint.host != nil else {
                    throw CloudDriveError.invalidResponse
                }
                var offset: Int64 = 0
                var sliceNo = 1
                while offset < size {
                    try Task.checkCancellation()
                    let count = min(Int64(sliceSize), size - offset)
                    let body = try await Task.detached(priority: .utility) { [offset, sliceNo] in
                        try Self.metadataSliceBody(
                            at: localURL, offset: offset, count: count,
                            uploadID: uploadID, sliceNo: sliceNo
                        )
                    }.value
                    do {
                        defer { try? FileManager.default.removeItem(at: body.url) }
                        try await uploadMetadataSlice(body.url, boundary: body.boundary, to: endpoint)
                    }
                    offset += count
                    sliceNo += 1
                }
                // Like Baidu, this API has no If-Match. Recheck immediately
                // before committing the detached chunks, including name/parent.
                _ = try await unchangedMetadataFile(at: path, expected: expected)
                replacementPath = try await completeMetadataUpload(uploadID)
            }
        } catch {
            // A lost create/complete response may hide a successful commit.
            // Resolve only an exact content match; do not blindly repeat writes.
            guard let recovered = try? await listFiles(at: String(original.parentID)).filter({
                !$0.isDirectory && $0.name == original.name && $0.size == size
                    && $0.revision?.lowercased() == md5
            }), recovered.count == 1, let item = recovered.first else { throw error }
            replacementPath = item.path
        }
        await invalidateMetadataWritebackCache(for: path)
        await invalidateMetadataWritebackCache(for: replacementPath)
        do {
            let committed = try await metadataFile(for: replacementPath)
            guard committed.parentID == original.parentID, committed.name == original.name,
                  committed.state.fileSize == size, committed.state.revision == md5 else {
                throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
            }
        } catch {
            guard replacementPath != path else { throw error }
            throw EmbeddedMetadataReplacementReadbackError(
                filePath: replacementPath, fileSize: size, detail: error.localizedDescription
            )
        }
        return replacementPath
    }

    /// 123 开放平台的 `upload_complete` 返回 `completed=false` 表示服务端仍在合并分片,
    /// 不是失败;需用同一个 preuploadID 重新调用直到 `completed && fileID != 0`
    /// (OpenList 123_open 驱动同样最多轮询 60 次、每次间隔 1 秒)。轮询用尽仍未完成时
    /// 抛 `Pan123UploadMergePendingError`,由调用方按名字/大小/md5 列目录恢复。
    /// POST 不走传输层重试,轮询只在这里做。
    private func completeMetadataUpload(_ uploadID: String) async throws -> String {
        let body = try JSONSerialization.data(withJSONObject: ["preuploadID": uploadID])
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let complete = try await authedRequest(
                "/upload/v2/file/upload_complete", method: "POST", body: body
            )
            guard let result = complete["data"] as? [String: Any] else {
                throw CloudDriveError.invalidResponse
            }
            if Self.intValue(result["completed"]) == 1,
               let fileID = Self.intValue(result["fileID"] ?? result["fileId"]), fileID > 0 {
                return String(fileID)
            }
            guard attempt < uploadCompletionPollLimit else {
                throw Pan123UploadMergePendingError(attempts: attempt)
            }
            try Task.checkCancellation()
            try await Task.sleep(for: uploadCompletionPollInterval)
        }
    }

    private static func uploadedFileID(_ data: [String: Any]) throws -> String {
        guard let id = intValue(data["fileID"] ?? data["fileId"]), id > 0 else {
            throw CloudDriveError.invalidResponse
        }
        return String(id)
    }

    private static func metadataMD5(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = Insecure.MD5()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func metadataSliceBody(
        at source: URL, offset: Int64, count: Int64, uploadID: String, sliceNo: Int
    ) throws -> (url: URL, boundary: String) {
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        func readSlice(_ consume: (Data) throws -> Void) throws {
            try input.seek(toOffset: UInt64(offset))
            var remaining = count
            while remaining > 0 {
                try Task.checkCancellation()
                guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))),
                      !data.isEmpty else { throw CloudDriveError.invalidResponse }
                try consume(data)
                remaining -= Int64(data.count)
            }
        }
        var hash = Insecure.MD5()
        try readSlice { hash.update(data: $0) }
        let md5 = hash.finalize().map { String(format: "%02x", $0) }.joined()
        let boundary = "Primuse-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(boundary)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            let output = try FileHandle(forWritingTo: url)
            defer { try? output.close() }
            func text(_ value: String) throws { try output.write(contentsOf: Data(value.utf8)) }
            for (name, value) in [("preuploadID", uploadID), ("sliceNo", String(sliceNo)), ("sliceMD5", md5)] {
                try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            }
            try text("--\(boundary)\r\nContent-Disposition: form-data; name=\"slice\"; filename=\"slice\"\r\nContent-Type: application/octet-stream\r\n\r\n")
            try readSlice { try output.write(contentsOf: $0) }
            try text("\r\n--\(boundary)--\r\n")
            return (url, boundary)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func uploadMetadataSlice(_ body: URL, boundary: String, to url: URL) async throws {
        let token = try await getToken()
        let session = session
        try await helper.withTokenRetry(initialToken: token, refresh: refreshToken, isTokenRejection: Self.isAuthError) { @Sendable token in
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.timeoutInterval = 300
            let (data, response) = try await session.upload(for: request, fromFile: body)
            guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 401 || Self.intValue(json?["code"]) == 401 { throw CloudDriveError.tokenExpired }
            guard (200...299).contains(http.statusCode), Self.intValue(json?["code"]) == 0 else {
                throw CloudDriveError.apiError(Self.intValue(json?["code"]) ?? http.statusCode, json?["message"] as? String ?? "")
            }
        }
    }

    // MARK: - Sidecar 回写(单步上传)

    /// 把刮削的 sidecar(封面 `-cover.jpg` / 歌词 `.lrc`)上传回 123 云盘,放源歌曲同目录、
    /// 用源文件真实名命名(重扫时 findSameName* 能按同名读回 → 多设备共享)。
    /// `path` 由 SidecarWriteService 用 `song.filePath`(123 是 fileId)拼成,形如
    /// `"{fileId}-cover.jpg"` / `"{fileId}.lrc"`。反解 fileId → 查详情拿真实名 + 父目录 → 上传。
    func writeFile(data: Data, to path: String) async throws {
        let suffix: String
        if path.hasSuffix("-cover.jpg") { suffix = "-cover.jpg" }
        else if let lyricsExtension = PrimuseConstants.supportedLyricsExtensions.first(where: {
            path.hasSuffix(".\($0)")
        }) { suffix = ".\(lyricsExtension)" }
        else { throw CloudDriveError.invalidResponse }
        let fileID = String(path.dropLast(suffix.count))
        guard !fileID.isEmpty else { throw CloudDriveError.invalidResponse }

        // 1. 查源文件详情 → 真实文件名 + 父目录 id
        let detail = try await authedRequest("/api/v1/file/detail?fileID=\(fileID)")
        let d = detail["data"] as? [String: Any] ?? [:]
        guard let srcName = d["filename"] as? String,
              let parentID = Self.intValue(d["parentFileID"]) else {
            throw CloudDriveError.invalidResponse
        }
        let sidecarName = (srcName as NSString).deletingPathExtension + suffix

        // 2. 单步上传(multipart 一次完成),duplicate=2 覆盖原 sidecar
        let domain = try await uploadDomain()
        do {
            _ = try await singleStepUpload(
                domain: domain,
                parentFileID: parentID,
                filename: sidecarName,
                data: data
            )
        } catch {
            // Upload hosts are assigned dynamically and may be retired before
            // this actor is recreated. Refresh once; duplicate=2 makes retrying
            // the same sidecar idempotent if the first response was lost.
            cachedUploadDomain = nil
            let refreshedDomain = try await uploadDomain()
            _ = try await singleStepUpload(
                domain: refreshedDomain,
                parentFileID: parentID,
                filename: sidecarName,
                data: data
            )
        }
        let expectedMD5 = Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let matches = try await listFiles(at: String(parentID)).filter {
            !$0.isDirectory
                && $0.name == sidecarName
                && $0.size == Int64(data.count)
                && $0.revision?.caseInsensitiveCompare(expectedMD5) == .orderedSame
        }
        guard matches.count == 1, let sidecar = matches.first else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        invalidateDownloadURL(for: sidecar.path)
        helper.invalidateCachedFile(path: sidecar.path)
        let readback = try await fetchRange(
            path: sidecar.path,
            offset: 0,
            length: Int64(data.count)
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        plog("📁 123 sidecar uploaded and verified: \(sidecarName)")
    }

    func verifySidecarWrite(data: Data, at path: String) async throws {
        // `writeFile` resolves the resulting file id and performs exact readback.
    }

    func writeLyricsSidecar(
        data: Data,
        target: LyricsSidecarTarget,
        priority: RangeFetchPriority
    ) async throws -> LyricsSidecarWriteReceipt {
        let targetExtension = (target.fileName as NSString).pathExtension.lowercased()
        guard !data.isEmpty,
              let parentID = Self.intValue(target.containerPath),
              PrimuseConstants.supportedLyricsExtensions.contains(targetExtension),
              target.targetPath.hasSuffix(".\(targetExtension)") else {
            throw CloudDriveError.invalidResponse
        }
        let sourceFileID = String(target.targetPath.dropLast(targetExtension.count + 1))
        let detail = try await authedRequest(
            "/api/v1/file/detail?fileID=\(sourceFileID)"
        )
        let source = detail["data"] as? [String: Any] ?? [:]
        guard let sourceName = source["filename"] as? String,
              Self.intValue(source["parentFileID"]) == parentID,
              (sourceName as NSString).deletingPathExtension
                .caseInsensitiveCompare((target.fileName as NSString).deletingPathExtension)
                == .orderedSame else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }

        let currentMatches = try await listFiles(at: target.containerPath).filter {
            !$0.isDirectory
                && $0.name.caseInsensitiveCompare(target.fileName) == .orderedSame
        }
        guard currentMatches.count <= 1 else {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        if target.exists {
            guard let existingPath = target.existingPath,
                  currentMatches.first?.path == existingPath else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
        } else if !currentMatches.isEmpty {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }

        let domain = try await uploadDomain()
        let uploadedFileID: String
        do {
            uploadedFileID = try await singleStepUpload(
                domain: domain,
                parentFileID: parentID,
                filename: target.fileName,
                data: data
            )
        } catch {
            cachedUploadDomain = nil
            let refreshedDomain = try await uploadDomain()
            uploadedFileID = try await singleStepUpload(
                domain: refreshedDomain,
                parentFileID: parentID,
                filename: target.fileName,
                data: data
            )
        }

        let expectedMD5 = Insecure.MD5.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
        let uploadedDetail = try await authedRequest(
            "/api/v1/file/detail?fileID=\(uploadedFileID)"
        )
        let uploaded = uploadedDetail["data"] as? [String: Any] ?? [:]
        let remoteSize = (uploaded["size"] as? Int64)
            ?? Int64(Self.intValue(uploaded["size"]) ?? -1)
        if let returnedID = uploaded["fileID"] ?? uploaded["fileId"],
           Self.idString(returnedID) != uploadedFileID {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        guard uploaded["filename"] as? String == target.fileName,
              Self.intValue(uploaded["parentFileID"]) == parentID,
              remoteSize == Int64(data.count),
              (uploaded["etag"] as? String)?
                .caseInsensitiveCompare(expectedMD5) == .orderedSame else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        invalidateDownloadURL(for: uploadedFileID)
        helper.invalidateCachedFile(path: uploadedFileID)
        let readback = try await fetchRange(
            path: uploadedFileID,
            offset: 0,
            length: remoteSize
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        return LyricsSidecarWriteReceipt(
            requestedTargetPath: target.targetPath,
            writtenPath: uploadedFileID,
            fileName: target.fileName,
            containerPath: target.containerPath,
            remoteSize: remoteSize,
            readback: readback
        )
    }

    func lyricsSidecarTarget(for song: Song) async throws -> LyricsSidecarTarget {
        let detail = try await authedRequest("/api/v1/file/detail?fileID=\(song.filePath)")
        let data = detail["data"] as? [String: Any] ?? [:]
        guard let sourceName = data["filename"] as? String,
              let parentID = Self.intValue(data["parentFileID"]) else {
            throw CloudDriveError.invalidResponse
        }
        let baseName = (sourceName as NSString).deletingPathExtension
        let siblings = try await listFiles(at: String(parentID))
        let existing = try LyricsSidecarTargetPolicy.uniqueExistingItem(
            baseName: baseName,
            in: siblings
        )
        let companion = LyricsSidecarTargetPolicy.translationTrackItem(
            forPrimary: existing,
            baseName: baseName,
            in: siblings
        )
        let fileName = existing?.name ?? "\(baseName).lrc"
        let suffix = ".\((fileName as NSString).pathExtension.lowercased())"
        return LyricsSidecarTarget(
            targetPath: song.filePath + suffix,
            fileName: fileName,
            containerPath: String(parentID),
            exists: existing != nil,
            existingPath: existing?.path,
            existingSize: existing?.size,
            songBaseName: baseName,
            translationPath: companion?.path,
            translationFileName: companion?.name,
            translationSize: companion?.size
        )
    }

    func deleteFile(at path: String) async throws {
        try await deleteFiles(at: [path])
    }

    func deleteFiles(at paths: [String]) async throws {
        let uniquePaths = Array(Set(paths))
        let ids = uniquePaths.compactMap(Self.intValue).sorted()
        guard !ids.isEmpty, ids.count == uniquePaths.count else {
            throw CloudDriveError.invalidResponse
        }
        let body = try SafeJSONSerialization.data(withJSONObject: ["fileIDs": ids])
        _ = try await authedRequest("/api/v1/file/trash", method: "POST", body: body)
        for path in uniquePaths { invalidateDownloadURL(for: path) }
        plog("🗑️ 123 Drive items moved to trash: \(ids.count)")
    }

    // MARK: - 上传辅助

    /// 获取上传域名(GET /upload/v2/file/domain → data:[域名]),短期缓存并在失败时刷新。
    private func uploadDomain() async throws -> String {
        if let cachedUploadDomain, cachedUploadDomain.expiresAt > Date() {
            return cachedUploadDomain.value
        }
        let json = try await authedRequest("/upload/v2/file/domain")
        let arr = json["data"] as? [String] ?? []
        let domain = (arr.first ?? Self.fallbackUploadDomain)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let components = URLComponents(string: domain),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false else {
            throw CloudDriveError.invalidResponse
        }
        cachedUploadDomain = (domain, Date().addingTimeInterval(Self.uploadDomainTTL))
        return domain
    }

    /// V2 单步上传:POST {上传域名}/upload/v2/file/single/create(multipart/form-data)。
    /// 适合 ≤1GB 小文件(封面/歌词),一次 HTTP 完成。etag 为文件 MD5(小写 hex)。
    private func singleStepUpload(
        domain: String,
        parentFileID: Int,
        filename: String,
        data: Data
    ) async throws -> String {
        let md5 = Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let url = URL(string: "\(domain)/upload/v2/file/single/create") else {
            throw CloudDriveError.invalidResponse
        }
        let token = try await getToken()
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken, isTokenRejection: Self.isAuthError) { @Sendable tok in
            let boundary = "----PrimuseBoundary\(UUID().uuidString)"
            var body = Data()
            func field(_ name: String, _ value: String) {
                body.append("--\(boundary)\r\n".data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
                body.append("\(value)\r\n".data(using: .utf8)!)
            }
            field("parentFileID", String(parentFileID))
            field("filename", filename)
            field("etag", md5)
            field("size", String(data.count))
            field("duplicate", "2")   // 同名覆盖,使重新刮削能更新封面/歌词
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: application/octet-stream\r\n\r\n".data(using: .utf8)!)
            body.append(data)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            req.timeoutInterval = 120
            let (respData, response) = try await URLSession.shared.upload(for: req, from: body)
            guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any] ?? [:]
            let code = Self.intValue(json["code"]) ?? -1
            if code == 401 { throw CloudDriveError.tokenExpired }
            guard code == 0 else { throw CloudDriveError.apiError(code, json["message"] as? String ?? "") }
            guard let result = json["data"] as? [String: Any],
                  (result["completed"] as? Bool == true
                    || Self.intValue(result["completed"]) == 1),
                  let rawFileID = result["fileID"] ?? result["fileId"] else {
                throw CloudDriveError.invalidResponse
            }
            let uploadedFileID = Self.idString(rawFileID)
            guard !uploadedFileID.isEmpty else {
                throw CloudDriveError.invalidResponse
            }
            return uploadedFileID
        }
    }

    // MARK: - 下载直链

    private func getDownloadURL(for fileId: String) async throws -> URL {
        if let cached = downloadURLCache[fileId], cached.expiresAt > Date() { return cached.url }
        let json = try await authedRequest("/api/v1/file/download_info?fileId=\(fileId)")
        let data = json["data"] as? [String: Any] ?? [:]
        guard let link = data["downloadUrl"] as? String, let url = URL(string: link) else {
            throw CloudDriveError.fileNotFound(fileId)
        }
        downloadURLCache[fileId] = (url, Date().addingTimeInterval(Self.downloadURLTTL))
        return url
    }

    private func invalidateDownloadURL(for fileId: String) {
        downloadURLCache.removeValue(forKey: fileId)
    }

    // MARK: - 鉴权请求(Platform 头 + code==0 校验 + 401 刷新重试)

    /// 发一个带 `Platform: open_platform` + `Authorization` 的请求,校验 body `code==0`,
    /// 失败抛 `CloudDriveError.apiError`。HTTP 401 或 body code 401 → withTokenRetry
    /// 强制刷新 token 重试一次。返回顶层 JSON(调用方读 `["data"]`)。
    @discardableResult
    private func authedRequest(_ pathAndQuery: String, method: String = "GET", body: Data? = nil) async throws -> [String: Any] {
        let token = try await getToken()
        let session = session
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken, isTokenRejection: Self.isAuthError) { @Sendable tok in
            var req = URLRequest(url: URL(string: Self.apiBase + pathAndQuery)!)
            req.httpMethod = method
            req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            req.setValue("open_platform", forHTTPHeaderField: "Platform")
            if let body {
                req.httpBody = body
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            }
            req.timeoutInterval = 60
            let mayRetry = method.uppercased() == "GET"
            var transientAttempt = 0
            var delay: TimeInterval = 0.75
            while true {
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: req)
                } catch {
                    let nsError = error as NSError
                    guard mayRetry,
                          nsError.domain == NSURLErrorDomain,
                          CloudHTTPRetryPolicy.shouldRetry(urlErrorCode: nsError.code),
                          transientAttempt < 4 else { throw error }
                    transientAttempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 8)
                    continue
                }
                guard let http = response as? HTTPURLResponse else {
                    throw CloudDriveError.invalidResponse
                }
                if mayRetry,
                   CloudHTTPRetryPolicy.shouldRetry(statusCode: http.statusCode),
                   transientAttempt < 4 {
                    transientAttempt += 1
                    try await Task.sleep(for: .seconds(delay))
                    delay = min(delay * 2, 8)
                    continue
                }
                if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
                if http.statusCode == 403 { throw CloudDriveError.permissionDenied(.fileRead) }
                if http.statusCode == 404 { throw CloudDriveError.fileNotFound(pathAndQuery) }
                if http.statusCode == 429 { throw CloudDriveError.rateLimited }
                guard (200...299).contains(http.statusCode) else {
                    throw CloudDriveError.apiError(
                        http.statusCode,
                        String(data: data, encoding: .utf8) ?? ""
                    )
                }
                guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let code = Self.intValue(json["code"]) else {
                    throw CloudDriveError.invalidResponse
                }
                if code == 401 { throw CloudDriveError.tokenExpired }
                if code == 429 { throw CloudDriveError.rateLimited }
                guard code == 0 else {
                    throw CloudDriveError.apiError(code, json["message"] as? String ?? "")
                }
                return json
            }
        }
    }

    // MARK: - Token

    private func getToken() async throws -> String {
        if let tokenProvider { return try await tokenProvider() }
        // proactive:本地标记过期才刷新,与 reactive(401)共享 CloudTokenManager 的去重刷新,
        // 避免单次有效的 refresh_token 被并发刷新作废。
        return try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    /// 用 refresh_token 换新 access_token。123 的 oauth2/access_token 用 QueryString 传参,
    /// 且 refresh_token 单次有效 —— 必须保存返回的新 refresh_token(refreshDeduped 会落库)。
    /// nonisolated:只用 helper(Sendable)/静态常量/URLSession,不碰 actor 可变状态。
    private nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = try await helper.tokenManager.requireAppCredentials()
        guard !creds.clientId.isEmpty else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var comps = URLComponents(string: Self.tokenURL)!
        comps.queryItems = [
            .init(name: "client_id", value: creds.clientId),
            .init(name: "client_secret", value: creds.clientSecret ?? ""),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: rt),
        ]
        guard let tokenURL = FormSafeQueryURLBuilder.url(from: comps) else {
            throw CloudDriveError.invalidResponse
        }
        var req = URLRequest(url: tokenURL)
        req.httpMethod = "POST"
        req.setValue("open_platform", forHTTPHeaderField: "Platform")
        let (data, response) = try await URLSession.shared.data(for: req)
        let envelope = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        var json = envelope
        if let inner = envelope["data"] as? [String: Any] { json = inner }   // 兼容 {code,data:{…}} 包裹
        guard let at = json["access_token"] as? String else {
            let code = envelope["code"] as? Int
            throw CloudDriveHelper.tokenRefreshFailure(
                statusCode: code == 0 ? (response as? HTTPURLResponse)?.statusCode : code,
                providerErrorCode: envelope["error"] as? String
            )
        }
        let expiresIn = (json["expires_in"] as? TimeInterval) ?? 30 * 24 * 3600
        return .init(accessToken: at,
                     refreshToken: json["refresh_token"] as? String ?? rt,
                     expiresAt: Date().addingTimeInterval(expiresIn))
    }

    /// 第三方挂载应用 OAuth(authorization_code)。123 授权服务器直接回调已登记的
    /// `primuse://oauth/123pan/callback`;scope 固定且逗号分隔;无 PKCE。
    static func oauthConfig(clientId: String, clientSecret: String?) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .pan123,
            authURL: authURL,
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: clientSecret,
            scopes: ["user:base", "file:all:read", "file:all:write"],
            redirectURI: redirectURI,
            scopeSeparator: ",",
            usesPKCE: false
        )
    }

    // MARK: - 小工具

    /// 123 的鉴权类错误:HTTP 401(tokenExpired)或 body code 401。
    private static func isAuthError(_ error: Error) -> Bool {
        if case CloudDriveError.tokenExpired = error { return true }
        if case CloudDriveError.apiError(401, _) = error { return true }
        return false
    }

    /// JSON 数字可能被 JSONSerialization 解析为 Int / NSNumber / String,统一取 Int。
    private static func intValue(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let n = v as? NSNumber { return n.intValue }
        if let s = v as? String { return Int(s) }
        return nil
    }

    private static func idString(_ v: Any) -> String {
        if let i = v as? Int { return String(i) }
        if let n = v as? NSNumber { return n.stringValue }
        if let s = v as? String { return s }
        return String(describing: v)
    }
}

/// 123 云盘分片上传在轮询上限内一直没有确认合并完成(`upload_complete` 始终 `completed=false`)。
struct Pan123UploadMergePendingError: LocalizedError {
    let attempts: Int
    // 复用已本地化的 API 错误框架;文案点明是合并未完成,而非响应无效。
    var errorDescription: String? {
        String(
            format: String(localized: "error_api %@ %@"),
            "upload_complete",
            "completed=false ×\(attempts) (merge pending)"
        )
    }
}
