import CryptoKit
import Foundation
import FilesProvider
import PrimuseKit

actor WebDAVSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let useSsl: Bool
    private let basePath: String?
    private let username: String
    private let password: String
    private var provider: WebDAVFileProvider?
    private let cacheDirectory: URL

    /// 长生命周期 session, 让 fetchRange 复用 HTTP keep-alive 连接,
    /// 避免每次 chunk fetch 都重新 SSL handshake。
    /// 8 路并发: 配合 CloudPlaybackSource 小文件全 prefetch 时多 chunk 并发。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        useSsl: Bool,
        basePath: String? = nil,
        username: String,
        password: String
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.useSsl = useSsl
        self.basePath = basePath
        self.username = username
        self.password = password

        // Per-source cache dir avoids file-name collisions when two WebDAV sources
        // happen to expose files with the same relative path.
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_webdav_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if provider != nil {
            return
        }

        // 匿名 WebDAV 必须完全不带凭据；传一个 user/password 都为空的
        // URLCredential 仍可能让底层生成空的 Authorization challenge 响应。
        let credential: URLCredential? = if username.isEmpty && password.isEmpty {
            nil
        } else {
            URLCredential(user: username, password: password, persistence: .forSession)
        }

        guard let provider = WebDAVFileProvider(
            baseURL: try serverURL(),
            credential: credential
        ) else {
            throw SourceError.connectionFailed("Invalid WebDAV URL")
        }

        self.provider = provider

        do {
            _ = try await listFiles(at: "/")
        } catch {
            self.provider = nil
            throw error
        }
    }

    func disconnect() async {
        provider = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let providerPath = providerRelativePath(path)

        return try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: providerPath) { contents, error in
                if let error {
                    // Re-throw the underlying NSError so SSLTrustStore can detect
                    // certificate errors and prompt the user. Wrapping it in
                    // SourceError.connectionFailed(_:) loses domain/code/userInfo.
                    continuation.resume(throwing: error)
                    return
                }

                let items = contents
                    .filter { !$0.name.hasPrefix(".") }
                    .map { file -> RemoteFileItem in
                        RemoteFileItem(
                            name: file.name,
                            path: file.path,
                            isDirectory: file.isDirectory,
                            size: file.size,
                            modifiedDate: file.modifiedDate
                        )
                    }
                    .sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

                continuation.resume(returning: items)
            }
        }
    }

    private static func cacheFileName(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        let ext = (path as NSString).pathExtension
        return ext.isEmpty ? hash : "\(hash).\(ext)"
    }

    func localURL(for path: String) async throws -> URL {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        // 缓存名用 SHA256 哈希: 朴素的 '/' → '_' 替换会让 "/A/B.mp3" 与 "/A_B.mp3"
        // 撞到同一缓存键、播到错误文件。
        let baseName = Self.cacheFileName(for: path)
        let localPath = cacheDirectory.appendingPathComponent(baseName)

        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath
        }

        let providerPath = providerRelativePath(path)

        // Download to a sibling temp path then atomically rename. FilesProvider's
        // copyItem moves a (possibly truncated) temp file to the destination even
        // on failure, so writing straight to localPath would leave a half-written
        // file that future calls treat as a complete cache hit (and never self-heal).
        let tempPath = cacheDirectory.appendingPathComponent(
            "\(baseName).part-\(UUID().uuidString)"
        )

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                provider.copyItem(path: providerPath, toLocalURL: tempPath) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
            try FileManager.default.moveItem(at: tempPath, to: localPath)
        } catch {
            try? FileManager.default.removeItem(at: tempPath)
            throw error
        }
        return localPath
    }

    func deleteFile(at path: String) async throws {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let providerPath = providerRelativePath(path)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            provider.removeItem(path: providerPath) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
                    defer { handle.closeFile() }
                    let chunkSize = 64 * 1024
                    while true {
                        let data = handle.readData(ofLength: chunkSize)
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

    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        guard let rangeHeader = SafeByteRange.httpHeader(offset: offset, length: length) else {
            return Data()
        }
        var request = URLRequest(url: try fileURL(for: path))
        request.httpMethod = "GET"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        if !username.isEmpty || !password.isEmpty {
            let credential = Data("\(username):\(password)".utf8).base64EncodedString()
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30

        let (data, response) = try await rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid WebDAV range response")
        }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            let totalSize = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, totalSize + offset) : offset
            guard actualOffset < totalSize else { return Data() }
            guard let requestedEnd = SafeByteRange.exclusiveEnd(offset: actualOffset, length: length) else {
                return Data()
            }
            let upper = min(requestedEnd, totalSize)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw SourceError.connectionFailed("WebDAV range request failed: HTTP \(http.statusCode)")
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    try await self.scanDirectory(path: path, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private func scanDirectory(
        path: String,
        continuation: AsyncThrowingStream<RemoteFileItem, Error>.Continuation
    ) async throws {
        let items = try await listFiles(at: path)

        for item in items {
            if item.isDirectory {
                try await scanDirectory(path: item.path, continuation: continuation)
            } else if let scannable = SidecarHintResolver.scannableItem(item, siblings: items) {
                continuation.yield(scannable)
            }
        }
    }

    /// Strips the leading "/" so the path is resolved relative to baseURL.
    /// WebDAVFileProvider does relative-URL resolution, and an absolute path
    /// (one that starts with "/") will replace baseURL's path component —
    /// dropping basePath entirely.
    private func providerRelativePath(_ path: String) -> String {
        if path == "/" { return "" }
        return path.hasPrefix("/") ? String(path.dropFirst()) : path
    }

    private func serverURL() throws -> URL {
        let scheme = useSsl ? "https" : "http"
        guard let baseURL = NetworkURLBuilder.makeURL(
            host: host,
            defaultScheme: scheme,
            port: port,
            path: basePath
        ) else {
            throw SourceError.connectionFailed("Invalid WebDAV URL")
        }

        // WebDAVFileProvider needs a directory-style baseURL (trailing "/")
        // so that relative path resolution preserves basePath.
        let absolute = baseURL.absoluteString
        if absolute.hasSuffix("/") {
            return baseURL
        }
        return URL(string: absolute + "/") ?? baseURL
    }

    private func fileURL(for path: String) throws -> URL {
        var url = try serverURL()
        let relative = providerRelativePath(path)
        for component in relative.split(separator: "/") {
            url.appendPathComponent(String(component), isDirectory: false)
        }
        return url
    }
}
