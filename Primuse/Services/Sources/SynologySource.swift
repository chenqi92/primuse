import Foundation
import PrimuseKit

actor SynologySource: MusicSourceConnector {
    let sourceID: String

    private let api: SynologyAPI
    private let username: String
    private let password: String
    private let rememberDevice: Bool
    private let deviceId: String?
    private let cacheDirectory: URL

    init(
        sourceID: String, host: String, port: Int, useSsl: Bool,
        username: String, password: String,
        rememberDevice: Bool, deviceId: String?
    ) {
        self.sourceID = sourceID
        self.api = SynologyAPI(host: host, port: port, useSsl: useSsl)
        self.username = username
        self.password = password
        self.rememberDevice = rememberDevice
        self.deviceId = deviceId

        // Use Caches directory (survives app restarts, system can purge when low on storage)
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_audio_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        guard await api.isLoggedIn == false else { return }
        let result = await api.login(
            account: username, password: password,
            deviceName: rememberDevice ? "Primuse-iOS" : nil,
            deviceId: deviceId
        )
        guard result.success else {
            throw result.needs2FA
                ? SourceError.authenticationFailed
                : SourceError.connectionFailed(result.errorMessage ?? "Login failed")
        }
    }

    func disconnect() async {
        await api.logout()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(name: $0.name, path: $0.path, isDirectory: $0.isDirectory, size: $0.size, modifiedDate: nil)
        }
    }

    /// Download full file to cache for playback. Supports offline playback after first download.
    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)

        // Already cached — return immediately (works offline)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        // Must be online to download
        try await connect()

        guard let sid = await api.sid else { throw SynologyError.notLoggedIn }

        // Build download URL
        let baseURL = await api.baseURLString
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        guard let url = components.url else { throw SynologyError.invalidURL }

        // Download to temp file first, then move to cache
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // 5 min for large files
        config.timeoutIntervalForResource = 600 // 10 min total
        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)

        let (tempURL, response) = try await session.download(from: url)

        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw SynologyError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }

        // Move to cache
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)

        return fileURL
    }

    func streamingURL(for path: String) async throws -> URL? {
        try await connect()
        guard let sid = await api.sid else { throw SynologyError.notLoggedIn }

        let baseURL = await api.baseURLString
        var components = URLComponents(string: "\(baseURL)/webapi/entry.cgi")!
        components.queryItems = [
            URLQueryItem(name: "api", value: "SYNO.FileStation.Download"),
            URLQueryItem(name: "version", value: "2"),
            URLQueryItem(name: "method", value: "download"),
            URLQueryItem(name: "path", value: path),
            URLQueryItem(name: "mode", value: "download"),
            URLQueryItem(name: "_sid", value: sid),
        ]
        return components.url
    }

    /// Returns the local cache URL if the file is already cached, nil otherwise.
    nonisolated func cachedURL(for path: String) -> URL? {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        return FileManager.default.fileExists(atPath: fileURL.path) ? fileURL : nil
    }

    /// Download file to cache in background (for offline support).
    func cacheFile(for path: String) async throws {
        // Skip if already cached
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        guard !FileManager.default.fileExists(atPath: fileURL.path) else { return }

        guard let url = try await streamingURL(for: path) else { return }

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)

        let (tempURL, response) = try await session.download(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }

        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let localURL = try await localURL(for: path)
        return AsyncThrowingStream { continuation in
            Task {
                do {
                    let handle = try FileHandle(forReadingFrom: localURL)
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

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    try await scanDirectory(path: path, continuation: continuation)
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
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    continuation.yield(item)
                }
            }
        }
    }

    /// Cache size for this source
    func cacheSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return files.reduce(0) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    /// Clear cached files
    func clearCache() {
        try? FileManager.default.removeItem(at: cacheDirectory)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func writeFile(data: Data, to path: String) async throws {
        try await connect()
        let directory = (path as NSString).deletingLastPathComponent
        let fileName = (path as NSString).lastPathComponent
        try await api.uploadFile(data: data, toDirectory: directory, fileName: fileName)
    }
}
