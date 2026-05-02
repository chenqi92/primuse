import Foundation
import PrimuseKit

/// OAuth configuration for a cloud drive
struct CloudOAuthConfig: Sendable {
    let authURL: String
    let tokenURL: String
    let clientId: String
    let clientSecret: String?
    let scopes: [String]
    let redirectURI: String
    let scopeSeparator: String
    let usesPKCE: Bool
    /// 当 redirectURI 是 https 中转页时，必须显式指定真正回到 App 的自定义 scheme
    /// （ASWebAuthenticationSession 要监听这个 scheme 才能拦截到中转页 JS 跳回来的那一下）。
    /// 如果为 nil，则自动从 redirectURI 派生。
    let explicitCallbackScheme: String?

    static let callbackScheme = "primuse"

    var callbackURLScheme: String {
        explicitCallbackScheme
            ?? URLComponents(string: redirectURI)?.scheme
            ?? Self.callbackScheme
    }

    init(
        authURL: String,
        tokenURL: String,
        clientId: String,
        clientSecret: String?,
        scopes: [String],
        redirectURI: String,
        scopeSeparator: String = " ",
        usesPKCE: Bool = true,
        explicitCallbackScheme: String? = nil
    ) {
        self.authURL = authURL
        self.tokenURL = tokenURL
        self.clientId = clientId
        self.clientSecret = clientSecret
        self.scopes = scopes
        self.redirectURI = redirectURI
        self.scopeSeparator = scopeSeparator
        self.usesPKCE = usesPKCE
        self.explicitCallbackScheme = explicitCallbackScheme
    }
}

/// Common errors for cloud drive operations
enum CloudDriveError: Error, LocalizedError {
    case notAuthenticated
    case tokenExpired
    case tokenRefreshFailed(String)
    case apiError(Int, String)
    case invalidResponse
    case fileNotFound(String)
    case rateLimited

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Not authenticated"
        case .tokenExpired: return "Token expired"
        case .tokenRefreshFailed(let msg): return "Token refresh failed: \(msg)"
        case .apiError(let code, let msg): return "API error \(code): \(msg)"
        case .invalidResponse: return "Invalid response"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .rateLimited: return "Rate limited"
        }
    }
}

/// Shared HTTP + caching utilities for all cloud drive sources.
/// Each cloud source uses this as a helper instead of inheritance.
struct CloudDriveHelper: Sendable {
    let sourceID: String
    let tokenManager: CloudTokenManager

    var cacheDirectory: URL {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_cloud_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return cacheDir
    }

    init(sourceID: String) {
        self.sourceID = sourceID
        self.tokenManager = CloudTokenManager(sourceID: sourceID)
    }

    // MARK: - Range request

    /// HTTP Range GET. `offset < 0` means "from end" — translated to `Range: bytes=-N`.
    /// Always returns bytes whose semantic position is `[offset, offset+length)` of
    /// the underlying file:
    /// - 206 Partial Content: response body is exactly that slice — pass through.
    /// - 200 OK: server ignored our Range header and sent the full file. We slice
    ///   the requested window ourselves so callers can trust offsets. Without this
    ///   correction, a seek-to-middle would write the start of the file into the
    ///   middle of our cache and corrupt `.partial` permanently.
    func rangeRequest(
        url: URL,
        offset: Int64,
        length: Int64,
        accessToken: String? = nil,
        userAgent: String? = nil,
        referer: String? = nil
    ) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let rangeHeader: String
        if offset < 0 {
            rangeHeader = "bytes=\(offset)"  // suffix-byte-range form: bytes=-N
        } else {
            rangeHeader = "bytes=\(offset)-\(offset + length - 1)"
        }
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        if let accessToken {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
        if let userAgent {
            // Some providers (notably Baidu) refuse / throttle dlink fetches
            // unless the request looks like it's coming from their first-party
            // client. URLSession preserves custom headers across 302s, so this
            // also applies to the redirected CDN URL.
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CloudDriveError.invalidResponse }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            // Server returned the full file. Translate "from end" offsets to
            // a positive index into the body, then slice to the requested window.
            let totalSize = Int64(data.count)
            let actualOffset: Int64 = offset < 0
                ? max(0, totalSize + offset)
                : offset
            guard actualOffset < totalSize else { return Data() }
            let upper = min(actualOffset + length, totalSize)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            // Surface the status code so the caller can decide whether
            // it's recoverable (401/403/410 → token/dlink refresh) and
            // so the log shows which provider error triggered a
            // mid-stream playback failure.
            plog("⚠️ rangeRequest HTTP \(http.statusCode) for \(url.host ?? "?") path=\(url.path.suffix(60))")
            throw CloudDriveError.apiError(http.statusCode, "Range request failed")
        }
    }

    // MARK: - Authorized HTTP request

    func makeAuthorizedRequest(
        url: URL, method: String = "GET", body: Data? = nil,
        contentType: String? = nil, accessToken: String
    ) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        request.httpBody = body
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudDriveError.invalidResponse
        }
        if http.statusCode == 401 { throw CloudDriveError.tokenExpired }
        if http.statusCode == 429 { throw CloudDriveError.rateLimited }
        return (data, http)
    }

    // MARK: - Cache

    func cachedURL(for path: String) -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        return cacheDirectory.appendingPathComponent(sanitized)
    }

    func hasCached(path: String) -> Bool {
        FileManager.default.fileExists(atPath: cachedURL(for: path).path)
    }

    func cacheData(_ data: Data, for path: String) throws {
        try data.write(to: cachedURL(for: path))
    }

    // MARK: - Scan

    func scanAudioFiles(
        from path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem]
    ) -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, listFiles: listFiles, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// 最多同时递归这么多个子目录。Baidu/Aliyun 的 listFiles 在 actor 里串行，
    /// 加上 100ms 节流，并发在网络层不会真正提速；但能让 listFiles 结果的 JSON
    /// 解析、子目录排队、文件 yield 的 CPU 工作叠在 I/O 等待之上。
    private static let scanConcurrency = 4

    private func scanDirectory(
        path: String,
        listFiles: @escaping @Sendable (String) async throws -> [RemoteFileItem],
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(path)

        // 找当前目录里的封面/歌词文件，作为 sidecar 候选
        let nonAudio = items.filter { !$0.isDirectory && !PrimuseConstants.supportedAudioExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        let folderCover = findFolderCover(in: nonAudio)

        // 先把当前目录的音频文件 yield 出去，避免 ConnectorScanner 等子树扫完才开始处理
        for item in items where !item.isDirectory {
            let ext = (item.name as NSString).pathExtension.lowercased()
            if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                let basename = (item.name as NSString).deletingPathExtension
                let cover = findSameNameCover(basename: basename, in: nonAudio) ?? folderCover
                let lyrics = findSameNameLyrics(basename: basename, in: nonAudio)
                let withHints = RemoteFileItem(
                    name: item.name,
                    path: item.path,
                    isDirectory: false,
                    size: item.size,
                    modifiedDate: item.modifiedDate,
                    sidecarHints: (cover != nil || lyrics != nil)
                        ? SidecarHints(coverPath: cover, lyricsPath: lyrics)
                        : nil,
                    // Preserve provider revision (md5/etag/content_hash)
                    // through the sidecar-decoration step. Without this,
                    // each cloud connector's listFiles would surface a
                    // revision but ConnectorScanner — which consumes
                    // scanAudioFiles — would only ever see nil, defeating
                    // same-size overwrite detection on every cloud drive.
                    revision: item.revision
                )
                continuation.yield(withHints)
            }
        }

        let subdirs = items.filter { $0.isDirectory }
        guard !subdirs.isEmpty else { return }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var iterator = subdirs.makeIterator()
            // 启动 N 个并发 worker
            for _ in 0..<min(Self.scanConcurrency, subdirs.count) {
                guard let next = iterator.next() else { break }
                group.addTask { [self] in
                    try await scanDirectory(path: next.path, listFiles: listFiles, continuation: continuation)
                }
            }
            // 每完成一个就投下一个，保持 N 路并发
            while try await group.next() != nil {
                guard let next = iterator.next() else { continue }
                group.addTask { [self] in
                    try await scanDirectory(path: next.path, listFiles: listFiles, continuation: continuation)
                }
            }
        }
    }

    // MARK: - Sidecar lookup helpers

    /// Find `{basename}.{jpg,png,...}` or `{basename}-cover.{...}` in the same dir.
    private func findSameNameCover(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedCoverExtensions {
            if let m = candidates.first(where: {
                let n = ($0.name as NSString).lowercased
                return n == "\(baseLower).\(ext)" || n == "\(baseLower)-cover.\(ext)"
            }) { return m.path }
        }
        return nil
    }

    /// Find `cover.jpg`, `folder.jpg`, `album.jpg` etc. as a directory-wide fallback.
    private func findFolderCover(in candidates: [RemoteFileItem]) -> String? {
        for name in PrimuseConstants.folderCoverNames {
            for ext in PrimuseConstants.supportedCoverExtensions {
                if let m = candidates.first(where: {
                    ($0.name as NSString).lowercased == "\(name).\(ext)"
                }) { return m.path }
            }
        }
        return nil
    }

    /// Find `{basename}.{lrc,...}` in the same dir.
    private func findSameNameLyrics(basename: String, in candidates: [RemoteFileItem]) -> String? {
        let baseLower = basename.lowercased()
        for ext in PrimuseConstants.supportedLyricsExtensions {
            if let m = candidates.first(where: {
                ($0.name as NSString).lowercased == "\(baseLower).\(ext)"
            }) { return m.path }
        }
        return nil
    }

    // MARK: - Stream from cache

    func streamFromCache(path: String) -> AsyncThrowingStream<Data, Error> {
        let url = cachedURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: url)
                    defer { handle.closeFile() }
                    while true {
                        let data = handle.readData(ofLength: 64 * 1024)
                        if data.isEmpty { break }
                        continuation.yield(data)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
