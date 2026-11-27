import Foundation
import PrimuseKit

/// Google Drive Source — Drive API v3
actor GoogleDriveSource: MusicSourceConnector, OAuthCloudSource, RemoteFileDisplayNameProviding,
    IncrementalMusicSourceConnector, LyricsSidecarTargetResolving,
    EmbeddedMetadataWritebackAdapter {
    let sourceID: String
    nonisolated let supportsSidecarWriting = true   // 刮削歌词/封面写回 Google Drive 同目录
    let helper: CloudDriveHelper
    let tokenProvider: (@Sendable () async throws -> String)?
    /// 源上存的访问方式(授权时写入,见 `GoogleDrivePickerPolicy`)。它是构造参数,变了连接器会重建
    /// (`SourceManager.connectorConstructionSignature`)。
    let storedAccessMode: GoogleDrivePickerPolicy.AccessMode?
    /// 授权预览和测试给的令牌附加字段;nil 时从钥匙串读。给了 `tokenProvider` 而没给它时视为没有附加字段。
    let tokenExtraProvider: (@Sendable () async throws -> [String: String]?)?
    /// 已选文件模式下最近一次列出的已授权文件(原始条目,父目录是 Drive 里真实的文件夹)。一轮扫描先列
    /// 根目录,随后找歌词、封面的同目录文件都从这里取,不再每首歌把已授权文件重列一遍。上界是这个源
    /// 能看到的已授权文件数(选择器里选的文件加上 Primuse 写回的歌词和封面),不随整个云端硬盘或曲库
    /// 增长;写回、删除文件时作废。
    var authorizedFilesSnapshot: AuthorizedFilesSnapshot?
    struct AuthorizedFilesSnapshot {
        let items: [RemoteFileItem]
        let listedAt: Date
    }
    static let authorizedFilesSnapshotLifetime: TimeInterval = 10 * 60
    static let apiBase = "https://www.googleapis.com/drive/v3"
    private static let uploadBase = "https://www.googleapis.com/upload/drive/v3"
    // Drive v3 deliberately removed File.etag. Keep normal browsing on v3,
    // but use the still-supported v2 File ETag for atomic If-Match replacement.
    private static let metadataWritebackAPIBase = "https://www.googleapis.com/drive/v2"
    private static let metadataWritebackUploadBase = "https://www.googleapis.com/upload/drive/v2"
    private static let tokenURL = "https://oauth2.googleapis.com/token"
    private static let reversedClientIdKey = "PrimuseGoogleReversedClientID"

    /// 写 sidecar 到 Google Drive。filePath 是 file ID,SidecarWriteService 拼的 `to`
    /// 形如 "{fileID}-cover.jpg" / "{fileID}.lrc" / "{fileID}.ttml"。
    /// 反解出源 file → 查名+父目录 → multipart 上传。
    func writeFile(data: Data, to path: String) async throws {
        _ = try await writeSidecar(data: data, to: path, expectedLyricsTarget: nil)
    }

    func writeLyricsSidecar(
        data: Data,
        target: LyricsSidecarTarget,
        priority: RangeFetchPriority
    ) async throws -> LyricsSidecarWriteReceipt {
        let written = try await writeSidecar(
            data: data,
            to: target.targetPath,
            expectedLyricsTarget: target
        )
        return LyricsSidecarWriteReceipt(
            requestedTargetPath: target.targetPath,
            writtenPath: written.path,
            fileName: written.fileName,
            containerPath: written.containerPath,
            remoteSize: written.size,
            readback: written.readback
        )
    }

    nonisolated static func sidecarUploadError(status: Int, body: Data) -> any Error {
        // Drive also uses 403 for quotas. Only explicit permission reasons
        // allow local-only persistence after a rejected upload.
        if status == 403,
           let json = try? JSONSerialization.jsonObject(with: body.prefix(16 * 1024)) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let errors = error["errors"] as? [[String: Any]], !errors.isEmpty,
           errors.allSatisfy({ entry in
               guard let reason = entry["reason"] as? String else { return false }
               return [
                   "insufficientFilePermissions",
                   "insufficientPermissions",
                   "appNotAuthorizedToFile",
               ].contains(reason)
           }) {
            return SourceFileMutationError.permissionDenied
        }
        return CloudDriveError.apiError(status, "Google Drive upload failed")
    }

    private struct CompletedSidecarWrite: Sendable {
        let path: String
        let fileName: String
        let containerPath: String
        let size: Int64
        let readback: Data
    }

    private func writeSidecar(
        data: Data,
        to path: String,
        expectedLyricsTarget: LyricsSidecarTarget?
    ) async throws -> CompletedSidecarWrite {
        guard !data.isEmpty else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        guard let reference = GoogleDriveSidecarPolicy.reference(from: path) else {
            throw CloudDriveError.invalidResponse
        }

        let resolvedContext = try await sidecarContext(for: reference)
        let context: SidecarContext
        let existingID: String?
        if let target = expectedLyricsTarget {
            let targetExtension = (target.fileName as NSString).pathExtension.lowercased()
            let targetBaseName = (target.fileName as NSString).deletingPathExtension
            let resolvedBaseName = (resolvedContext.name as NSString).deletingPathExtension
            guard target.targetPath == path,
                  target.containerPath == resolvedContext.parentID,
                  targetBaseName.caseInsensitiveCompare(resolvedBaseName) == .orderedSame,
                  targetExtension == String(reference.suffix.dropFirst()).lowercased(),
                  PrimuseConstants.supportedLyricsExtensions.contains(targetExtension) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            let matches = try await siblingsInFolder(target.containerPath).filter {
                !$0.isDirectory
                    && $0.name.caseInsensitiveCompare(target.fileName) == .orderedSame
            }
            guard matches.count <= 1 else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            if target.exists {
                guard let expectedPath = target.existingPath,
                      matches.first?.path == expectedPath else {
                    throw EmbeddedMetadataWritebackSourceError.conflict
                }
                existingID = expectedPath
            } else {
                guard matches.isEmpty else {
                    throw EmbeddedMetadataWritebackSourceError.conflict
                }
                existingID = nil
            }
            context = SidecarContext(name: target.fileName, parentID: target.containerPath)
        } else {
            context = resolvedContext
            existingID = try await sidecarItemID(
                named: context.name,
                parentID: context.parentID
            )
        }

        let token = try await getToken()
        // Wrap both the metadata lookup and the upload so a server-side early
        // token revocation (401) triggers one force-refresh + retry of the
        // whole sidecar write rather than failing until local expiry.
        let (sidecarID, remoteSize): (String, Int64) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            guard let mime = GoogleDriveSidecarPolicy.mimeType(for: reference.suffix) else {
                throw CloudDriveError.invalidResponse
            }
            let request: URLRequest

            if let existingID {
                var components = URLComponents(string: "\(Self.uploadBase)/files/\(existingID)")!
                components.queryItems = [
                    .init(name: "uploadType", value: "media"),
                    .init(name: "supportsAllDrives", value: "true"),
                    .init(name: "fields", value: "id,name,size,parents"),
                ]
                var update = URLRequest(url: components.url!)
                update.httpMethod = "PATCH"
                update.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
                update.setValue(mime, forHTTPHeaderField: "Content-Type")
                request = update
            } else {
                let metaJSON = try SafeJSONSerialization.data(withJSONObject: [
                    "name": context.name,
                    "parents": [context.parentID],
                ])
                let boundary = "primuse\(UUID().uuidString)"
                var body = Data()
                body.append("--\(boundary)\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n".data(using: .utf8)!)
                body.append(metaJSON)
                body.append("\r\n--\(boundary)\r\nContent-Type: \(mime)\r\n\r\n".data(using: .utf8)!)
                body.append(data)
                body.append("\r\n--\(boundary)--".data(using: .utf8)!)

                var components = URLComponents(string: "\(Self.uploadBase)/files")!
                components.queryItems = [
                    .init(name: "uploadType", value: "multipart"),
                    .init(name: "supportsAllDrives", value: "true"),
                    .init(name: "fields", value: "id,name,size,parents"),
                ]
                var create = URLRequest(url: components.url!)
                create.httpMethod = "POST"
                create.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
                create.setValue("multipart/related; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
                create.httpBody = body
                request = create
            }

            let uploadBody = request.httpBody ?? data
            var uploadRequest = request
            uploadRequest.httpBody = nil
            let (responseData, resp) = try await self.helper.sendOnce(uploadRequest) { session, request in
                try await session.upload(for: request, from: uploadBody)
            }
            guard let http = resp as? HTTPURLResponse else {
                throw CloudDriveError.invalidResponse
            }
            if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
            guard (200...299).contains(http.statusCode) else {
                throw Self.sidecarUploadError(status: http.statusCode, body: responseData)
            }
            let responseJSON = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] ?? [:]
            guard let uploadedID = responseJSON["id"] as? String,
                  !uploadedID.isEmpty,
                  let uploadedName = responseJSON["name"] as? String,
                  uploadedName == context.name,
                  Self.int64(responseJSON["size"]) == Int64(data.count),
                  (responseJSON["parents"] as? [String])?.contains(context.parentID) == true else {
                throw CloudDriveError.invalidResponse
            }
            if let existingID, uploadedID != existingID {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            return (uploadedID, Self.int64(responseJSON["size"]))
        }

        // 刚写回的文件要出现在之后的同目录查找里。
        noteUploadedSidecar(id: sidecarID, name: context.name, parentID: context.parentID, size: remoteSize)
        let readback = try await fetchRange(
            path: sidecarID,
            offset: 0,
            length: remoteSize
        )
        guard readback == data else {
            throw EmbeddedMetadataWritebackSourceError.remoteVerificationFailed
        }
        if expectedLyricsTarget != nil,
           let visibleMatches = try? await siblingsInFolder(context.parentID, fresh: true).filter({
               !$0.isDirectory
                   && $0.name.caseInsensitiveCompare(context.name) == .orderedSame
           }),
           visibleMatches.count > 1
                || (visibleMatches.count == 1 && visibleMatches[0].path != sidecarID) {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        plog("📁 Google Drive sidecar uploaded and verified: \(context.name)")
        return CompletedSidecarWrite(
            path: sidecarID,
            fileName: context.name,
            containerPath: context.parentID,
            size: remoteSize,
            readback: readback
        )
    }

    private struct SidecarContext: Sendable {
        let name: String
        let parentID: String
    }

    private func sidecarContext(
        for reference: GoogleDriveSidecarReference
    ) async throws -> SidecarContext {
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(reference.sourceFileID)")!
        components.queryItems = [
            .init(name: "fields", value: "name,parents,trashed"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        let requestURL = components.url!
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: requestURL, accessToken: tok)
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, "Google Drive source file lookup failed")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard json["trashed"] as? Bool != true,
              let sourceName = json["name"] as? String,
              let parentID = (json["parents"] as? [String])?.first else {
            throw CloudDriveError.invalidResponse
        }
        return SidecarContext(
            name: GoogleDriveSidecarPolicy.targetName(
                sourceFileName: sourceName,
                suffix: reference.suffix
            ),
            parentID: parentID
        )
    }

    private func sidecarItemID(named name: String, parentID: String) async throws -> String? {
        let matches = try await siblingsInFolder(parentID).filter {
            !$0.isDirectory && $0.name.caseInsensitiveCompare(name) == .orderedSame
        }
        return matches.max {
            ($0.modifiedDate ?? .distantPast) < ($1.modifiedDate ?? .distantPast)
        }?.path
    }

    func lyricsSidecarTarget(
        for song: Song,
        request: LyricsDocumentRequest
    ) async throws -> LyricsSidecarTarget {
        let lrcReference = GoogleDriveSidecarReference(
            sourceFileID: song.filePath,
            suffix: ".lrc"
        )
        let lrcContext = try await sidecarContext(for: lrcReference)
        let siblings = try await siblingsInFolder(lrcContext.parentID)
        let baseName = (lrcContext.name as NSString).deletingPathExtension
        let existing = try LyricsSidecarTargetPolicy.uniqueExistingItem(
            baseName: baseName,
            in: siblings,
            request: request
        )
        let companion = LyricsSidecarTargetPolicy.translationTrackItem(
            forPrimary: existing,
            baseName: baseName,
            in: siblings
        )
        let suffix = existing.map { ".\(($0.name as NSString).pathExtension.lowercased())" }
            ?? ".lrc"
        let fileName = existing?.name ?? "\(baseName).lrc"
        return LyricsSidecarTarget(
            targetPath: song.filePath + suffix,
            fileName: fileName,
            containerPath: lrcContext.parentID,
            exists: existing != nil,
            existingPath: existing?.path,
            existingSize: existing?.size,
            songBaseName: baseName,
            translationPath: companion?.path,
            translationFileName: companion?.name,
            translationSize: companion?.size,
            documents: LyricsSidecarTargetPolicy.documents(baseName: baseName, in: siblings)
        )
    }

    private func resolvedDownloadPath(for path: String) async throws -> String {
        guard let reference = GoogleDriveSidecarPolicy.reference(from: path) else {
            return path
        }
        let context = try await sidecarContext(for: reference)
        guard let sidecarID = try await sidecarItemID(named: context.name, parentID: context.parentID) else {
            throw CloudDriveError.fileNotFound(context.name)
        }
        return sidecarID
    }

    private static func parseISO8601(_ s: String) -> Date? {
        // Drive's modifiedTime is RFC 3339 with fractional seconds.
        // Constructed per-call instead of cached because
        // ISO8601DateFormatter isn't Sendable under strict concurrency.
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    private struct MetadataDetail: Sendable {
        let state: EmbeddedMetadataRemoteFileState
        let eTag: String?
    }

    private static func metadataDetail(
        fileID: String,
        accessToken: String,
        helper: CloudDriveHelper
    ) async throws -> MetadataDetail {
        var components = URLComponents(
            string: "\(metadataWritebackAPIBase)/files/\(fileID)"
        )!
        components.queryItems = [
            .init(
                name: "fields",
                value: "id,fileSize,modifiedDate,md5Checksum,headRevisionId,mimeType,labels/trashed,etag"
            ),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60
        let (data, response) = try await helper.sendOnce(request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 404 { throw CloudDriveError.fileNotFound(fileID) }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["labels"] as? [String: Any])?["trashed"] as? Bool != true,
              (json["mimeType"] as? String) != "application/vnd.google-apps.folder" else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8)
                    ?? "Google Drive file lookup failed"
            )
        }
        let revision = (json["md5Checksum"] as? String)
            ?? (json["headRevisionId"] as? String)
        let eTag = json["etag"] as? String
        guard revision?.isEmpty == false, eTag?.isEmpty == false else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        return MetadataDetail(
            state: EmbeddedMetadataRemoteFileState(
                fileSize: int64(json["fileSize"]),
                modifiedDate: (json["modifiedDate"] as? String).flatMap(parseISO8601),
                revision: revision,
                replacementToken: eTag
            ),
            eTag: eTag
        )
    }

    private static func uploadMetadataFile(
        localURL: URL,
        fileID: String,
        expectedETag: String,
        accessToken: String,
        helper: CloudDriveHelper
    ) async throws {
        let size = Int64(
            try localURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        )
        var components = URLComponents(
            string: "\(metadataWritebackUploadBase)/files/\(fileID)"
        )!
        components.queryItems = [
            .init(name: "uploadType", value: "media"),
            .init(name: "supportsAllDrives", value: "true"),
            .init(
                name: "fields",
                value: "id,fileSize,modifiedDate,md5Checksum,headRevisionId,etag"
            ),
        ]
        var uploadRequest = URLRequest(url: components.url!)
        uploadRequest.httpMethod = "PUT"
        uploadRequest.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        uploadRequest.setValue(expectedETag, forHTTPHeaderField: "If-Match")
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(size), forHTTPHeaderField: "Content-Length")
        uploadRequest.timeoutInterval = 3_600
        let (data, response) = try await helper.sendOnce(uploadRequest) { session, request in
            try await session.upload(for: request, fromFile: localURL)
        }
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 409 || http.statusCode == 412 {
            throw EmbeddedMetadataWritebackSourceError.conflict
        }
        if http.statusCode == 403 { throw Self.sidecarUploadError(status: http.statusCode, body: data) }
        guard http.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["id"] as? String == fileID,
              ((json["md5Checksum"] as? String)?.isEmpty == false
                || (json["headRevisionId"] as? String)?.isEmpty == false) else {
            throw CloudDriveError.apiError(
                http.statusCode,
                String(data: data.prefix(4_096), encoding: .utf8)
                    ?? "Google Drive upload was not confirmed"
            )
        }
    }

    private static func int64(_ value: Any?) -> Int64 {
        if let value = value as? Int64 { return value }
        if let value = value as? Int { return Int64(value) }
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String, let parsed = Int64(value) { return parsed }
        return 0
    }

    init(sourceID: String, session: URLSession = .shared,
         tokenProvider: (@Sendable () async throws -> String)? = nil,
         requests: CloudRequestScheduler = .shared,
         storedAccessMode: GoogleDrivePickerPolicy.AccessMode? = nil,
         tokenExtraProvider: (@Sendable () async throws -> [String: String]?)? = nil) {
        self.sourceID = sourceID
        self.tokenProvider = tokenProvider
        self.storedAccessMode = storedAccessMode
        self.tokenExtraProvider = tokenExtraProvider
        self.helper = CloudDriveHelper(sourceID: sourceID, requests: requests, session: session,
                                       validateResponse: Self.validateQuota)
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        // 已选文件模式只有一个根;非根目录在 `resolvedAccessMode` 里已经判成要重新选择。
        if try await resolvedAccessMode(forPath: path) == .pickedFiles {
            return SidecarHintResolver.decorateGroupedByParent(
                try await refreshAuthorizedFilesSnapshot(),
                normalizedParentPath: GoogleDrivePickerPolicy.authorizedFilesRootPath
            )
        }

        let parentId = path.isEmpty || path == "/" ? "root" : path
        return try await listFilesMatching(
            query: "'\(parentId)' in parents and trashed = false",
            fallbackParentPath: parentId,
            notFoundTarget: parentId,
            isLegacyFolderListing: true
        )
    }

    func listFilesMatching(
        query: String,
        fallbackParentPath: String?,
        notFoundTarget: String,
        isLegacyFolderListing: Bool
    ) async throws -> [RemoteFileItem] {
        var all: [RemoteFileItem] = []
        var pageToken: String? = nil
        var seenPageTokens: Set<String> = []
        repeat {
            var components = URLComponents(string: "\(Self.apiBase)/files")!
            var items: [URLQueryItem] = [
                .init(name: "q", value: query),
                // md5Checksum / headRevisionId fingerprint a file even
                // when it's overwritten through the same id with the
                // same size — Drive keeps the id stable across version
                // uploads, and modifiedTime alone isn't enough when the
                // overwrite happens in the same second.
                .init(name: "fields", value: "files(id,name,mimeType,size,modifiedTime,md5Checksum,headRevisionId,parents),nextPageToken"),
                .init(name: "pageSize", value: "1000"),
                .init(name: "orderBy", value: "name"),
                .init(name: "supportsAllDrives", value: "true"),
                .init(name: "includeItemsFromAllDrives", value: "true"),
            ]
            if let p = pageToken { items.append(.init(name: "pageToken", value: p)) }
            components.queryItems = items
            let pageURL = components.url!
            let (data, http) = try await requestListPage(pageURL)
            if http.statusCode == 404 {
                // 已授权文件列表没有「这个目录不在了」一说:404 不能当成文件夹被删,让用户重新选择。
                guard isLegacyFolderListing else { throw SourceRootResolutionError.pickedFilesReselectionRequired }
                throw CloudDriveError.fileNotFound(notFoundTarget)
            }
            if http.statusCode == 403 {
                // 整盘授权被 Google 停用时 API 答「权限范围不够」:提示改用选择文件,不当成普通的文件权限问题。
                if isLegacyFolderListing, Self.isInsufficientScopeFailure(data) {
                    throw SourceRootResolutionError.googleDriveLegacyAccessDisabled
                }
                // Quota rejections already propagate a structured failure from
                // requestListPage; an ordinary 403 is a file permission failure.
                throw CloudDriveError.permissionDenied(.fileRead)
            }
            guard http.statusCode == 200 else { throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "") }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let files = json["files"] as? [[String: Any]] else {
                throw CloudDriveError.invalidResponse
            }
            all.append(contentsOf: try files.map { item in
                try Self.parseRemoteFileItem(item, fallbackParentPath: fallbackParentPath)
            })
            if let next = json["nextPageToken"] as? String {
                guard CloudPaginationTokenPolicy.canAdvance(
                    to: next,
                    seenTokens: seenPageTokens
                ) else {
                    throw CloudDriveError.invalidResponse
                }
                seenPageTokens.insert(next)
                pageToken = next
            } else {
                pageToken = nil
            }
        } while pageToken != nil
        return all
    }

    static func parseRemoteFileItem(
        _ item: [String: Any],
        fallbackParentPath: String?
    ) throws -> RemoteFileItem {
        guard let id = item["id"] as? String, let name = item["name"] as? String else {
            throw CloudDriveError.invalidResponse
        }
        let isDir = (item["mimeType"] as? String) == "application/vnd.google-apps.folder"
        let mtime = (item["modifiedTime"] as? String).flatMap(Self.parseISO8601)
        // Prefer md5Checksum (binary content fingerprint, doesn't
        // change unless bytes change). headRevisionId is a final
        // fallback — it changes per upload even when the file is
        // re-uploaded byte-identical, but that's still strictly
        // better than nil for catching overwrites.
        let revision = (item["md5Checksum"] as? String) ?? (item["headRevisionId"] as? String)
        return RemoteFileItem(
            name: name,
            path: id,
            isDirectory: isDir,
            size: Int64(item["size"] as? String ?? "0") ?? 0,
            modifiedDate: mtime,
            revision: revision,
            providerID: id,
            // `root` is only an API alias. Changes API returns the
            // actual root folder id, so persist that same identity to
            // avoid reconciling the top-level directory twice.
            parentPath: (item["parents"] as? [String])?.first ?? fallbackParentPath
        )
    }

    func requestListPage(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        let token = try await getToken()
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: url, accessToken: tok)
        }
    }

    private nonisolated static func validateQuota(_ data: Data, _ http: HTTPURLResponse) throws {
        if GoogleDriveHTTPErrorPolicy.disposition(
            statusCode: http.statusCode, reasons: errorReasons(from: data)
        ) == .retryRateLimit {
            throw HTTPResponseFailure(
                statusCode: http.statusCode, body: data,
                retryAfter: HTTPResponseFailure.retryDelay(from: http), isRateLimited: true
            )
        }
    }

    private nonisolated static func errorReasons(from data: Data) -> Set<String> {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let error = json["error"] as? [String: Any],
              let errors = error["errors"] as? [[String: Any]] else {
            return []
        }
        return Set(errors.compactMap { $0["reason"] as? String })
    }

    func localURL(for path: String) async throws -> URL {
        if helper.hasCached(path: path) { return helper.cachedURL(for: path) }
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(path)")!
        components.queryItems = [
            .init(name: "alt", value: "media"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        let mediaURL = components.url!
        return try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            var request = URLRequest(url: mediaURL)
            request.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization")
            return try await self.helper.downloadToCache(request: request, for: path)
        }
    }

    func metadataWritebackState(for path: String) async throws -> EmbeddedMetadataRemoteFileState {
        let token = try await getToken()
        let detail = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            try await Self.metadataDetail(fileID: path, accessToken: accessToken, helper: self.helper)
        }
        return detail.state
    }

    func replaceMetadataFile(
        at path: String,
        with localURL: URL,
        expected: EmbeddedMetadataRemoteFileState
    ) async throws {
        guard expected.revision?.isEmpty == false,
              expected.replacementToken?.isEmpty == false else {
            throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
        }
        let token = try await getToken()
        try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable accessToken in
            let detail = try await Self.metadataDetail(
                fileID: path,
                accessToken: accessToken,
                helper: self.helper
            )
            guard expected.matches(detail.state) else {
                throw EmbeddedMetadataWritebackSourceError.conflict
            }
            guard let eTag = detail.eTag, !eTag.isEmpty else {
                throw EmbeddedMetadataWritebackSourceError.missingStrongRevision
            }
            try await Self.uploadMetadataFile(
                localURL: localURL,
                fileID: path,
                expectedETag: eTag,
                accessToken: accessToken,
                helper: self.helper
            )
        }
        await invalidateMetadataWritebackCache(for: path)
    }

    func invalidateMetadataWritebackCache(for path: String) async {
        helper.invalidateCachedFile(path: path)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        _ = try await localURL(for: path)
        return helper.streamFromCache(path: path)
    }

    func displayName(for path: String) async throws -> String? {
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(path)")!
        components.queryItems = [
            .init(name: "fields", value: "name"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        let nameURL = components.url!
        let (data, http) = try await helper.withTokenRetry(initialToken: token, refresh: refreshToken) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(url: nameURL, accessToken: tok)
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, "Google Drive file name lookup")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["name"] as? String
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        helper.scanAudioFiles(from: path) { [self] p in try await listFiles(at: p) }
    }

    /// Recoverable deletion: mark the Drive file as trashed and require the
    /// updated resource to explicitly confirm `trashed=true`.
    func deleteFile(at path: String) async throws {
        guard !path.isEmpty else { throw CloudDriveError.invalidResponse }
        let resolvedPath = try await resolvedDownloadPath(for: path)
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(resolvedPath)")!
        components.queryItems = [
            .init(name: "supportsAllDrives", value: "true"),
            .init(name: "fields", value: "id,trashed"),
        ]
        guard let deleteURL = components.url else { throw CloudDriveError.invalidResponse }
        let body = try SafeJSONSerialization.data(withJSONObject: ["trashed": true])
        let (data, http) = try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken
        ) { @Sendable tok in
            try await self.helper.makeAuthorizedRequest(
                url: deleteURL, method: "PATCH", body: body,
                contentType: "application/json", accessToken: tok
            )
        }
        guard http.statusCode == 200 else {
            throw CloudDriveError.apiError(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        guard json["trashed"] as? Bool == true else {
            throw CloudDriveError.apiError(http.statusCode, "Google Drive did not confirm trashed=true")
        }
        authorizedFilesSnapshot = nil
        plog("🗑️ Google Drive item moved to trash: \(resolvedPath)")
    }

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        let resolvedPath = try await resolvedDownloadPath(for: path)
        let token = try await getToken()
        var components = URLComponents(string: "\(Self.apiBase)/files/\(resolvedPath)")!
        // `acknowledgeAbuse=true` is required for files Google's automated
        // scanner flagged as "potentially malicious" — without it, large
        // audio files occasionally come back as an HTML warning page
        // instead of bytes, which SFB then fails to decode. alist's
        // driver pins this verbatim too.
        components.queryItems = [
            .init(name: "alt", value: "media"),
            .init(name: "acknowledgeAbuse", value: "true"),
            .init(name: "supportsAllDrives", value: "true"),
        ]
        let mediaURL = components.url!
        // rangeRequest authenticates with a Bearer token, so a server-side
        // early revocation surfaces as apiError(401). Force a refresh + retry.
        return try await helper.withTokenRetry(
            initialToken: token,
            refresh: refreshToken,
            isTokenRejection: { if case CloudDriveError.apiError(401, _) = $0 { return true }; return false }
        ) { @Sendable tok in
            try await self.helper.rangeRequest(url: mediaURL, offset: offset, length: length, accessToken: tok)
        }
    }

    func getToken() async throws -> String {
        if let tokenProvider { return try await tokenProvider() }
        // proactive 路径: 本地标记过期才刷新, 与 reactive(401)路径共享 CloudTokenManager
        // 里的同一个 in-flight 去重任务, 避免轮换型 refresh_token 被并发刷新作废。
        return try await helper.tokenManager.refreshDeduped(.ifExpired, refresh: refreshToken).accessToken
    }

    // nonisolated: 只用 helper(Sendable)/静态常量/URLSession, 不碰可变 actor 状态,
    // 这样能作为 @Sendable 闭包传给 tokenManager.refreshDeduped / withTokenRetry。
    nonisolated func refreshToken(_ tokens: CloudTokenManager.Tokens) async throws -> CloudTokenManager.Tokens {
        guard let rt = tokens.refreshToken else { throw CloudDriveError.tokenRefreshFailed("No refresh token") }
        let creds = try await helper.tokenManager.requireAppCredentials()
        guard !creds.clientId.isEmpty else { throw CloudDriveError.tokenRefreshFailed("No client ID") }
        var request = URLRequest(url: URL(string: Self.tokenURL)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = CloudDriveHelper.formURLEncodedBody([
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: rt),
            URLQueryItem(name: "client_id", value: creds.clientId),
        ])
        let (data, response) = try await helper.tokenRequest(request, clientID: creds.clientId, session: URLSession.shared)
        let json = try CloudDriveHelper.tokenRefreshJSON(data: data, response: response)
        guard let at = json["access_token"] as? String else {
            throw CloudDriveHelper.tokenRefreshFailure(statusCode: (response as? HTTPURLResponse)?.statusCode)
        }
        let rotatedRefresh = (json["refresh_token"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mergedExtra = GoogleDrivePickerPolicy.mergedTokenExtra(
            existing: tokens.extra,
            incoming: nil,
            grantedScope: json["scope"] as? String
        )
        return .init(
            accessToken: at,
            refreshToken: (rotatedRefresh?.isEmpty == false ? rotatedRefresh : nil) ?? rt,
            expiresAt: Date().addingTimeInterval(json["expires_in"] as? TimeInterval ?? 3600),
            tokenType: (json["token_type"] as? String) ?? tokens.tokenType,
            extra: mergedExtra
        )
    }

    static func oauthConfig(clientId: String) -> CloudOAuthConfig {
        CloudOAuthConfig(
            provider: .googleDrive,
            authURL: "https://accounts.google.com/o/oauth2/v2/auth",
            tokenURL: tokenURL,
            clientId: clientId,
            clientSecret: nil,
            scopes: [GoogleDrivePickerPolicy.fileScope],
            redirectURI: redirectURI()
        )
    }

    private static func redirectURI() -> String {
        if let scheme = Bundle.main.object(forInfoDictionaryKey: reversedClientIdKey) as? String {
            let trimmed = scheme.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return "\(trimmed):/oauth2redirect"
            }
        }
        return "\(CloudOAuthConfig.callbackScheme)://google/callback"
    }
}
