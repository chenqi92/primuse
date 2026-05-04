import Foundation
import PrimuseKit

actor UgreenSource: MusicSourceConnector {
    let sourceID: String
    private let api: UgreenAPI
    private let username: String
    private let password: String
    private let cacheDirectory: URL

    /// 长生命周期 session, fetchRange 复用 HTTP keep-alive。
    private lazy var rangeSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
    }()

    init(sourceID: String, host: String, port: Int, useSsl: Bool,
         username: String, password: String) {
        self.sourceID = sourceID
        self.api = UgreenAPI(host: host, port: port, useSsl: useSsl)
        self.username = username; self.password = password
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("primuse_audio_cache/\(sourceID)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.cacheDirectory = dir
    }

    func connect() async throws {
        guard await !api.isLoggedIn else { return }
        let r = await api.login(account: username, password: password)
        guard r.success else {
            throw r.needs2FA ? SourceError.authenticationFailed
                             : SourceError.connectionFailed(r.errorMessage ?? "Ugreen login failed")
        }
    }

    func disconnect() async { await api.logout() }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(name: $0.name, path: $0.path.isEmpty ? "\(path)/\($0.name)" : $0.path,
                          isDirectory: $0.isDirectory, size: $0.size, modifiedDate: nil)
        }
    }

    func localURL(for path: String) async throws -> URL {
        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)
        if FileManager.default.fileExists(atPath: fileURL.path) { return fileURL }
        try await connect()
        guard let url = await api.downloadURL(path: path) else { throw SourceError.fileNotFound(path) }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 600
        let session = URLSession(configuration: config, delegate: SmartSSLDelegate(), delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        return fileURL
    }

    /// HTTP Range GET on Ugreen download URL。downloadURL 返回的 URL 已带认证,
    /// 标准 Range header 直接生效, 让 CloudPlaybackSource 边下边播替代整文件
    /// 下载。
    func fetchRange(path: String, offset: Int64, length: Int64) async throws -> Data {
        try await connect()
        guard let url = await api.downloadURL(path: path) else {
            throw SourceError.fileNotFound(path)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        let rangeHeader = offset < 0
            ? "bytes=\(offset)"
            : "bytes=\(offset)-\(offset + length - 1)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        request.timeoutInterval = 60

        let (data, response) = try await rangeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw SourceError.connectionFailed("Invalid Ugreen range response")
        }
        switch http.statusCode {
        case 206:
            return data
        case 200:
            let total = Int64(data.count)
            let actualOffset = offset < 0 ? max(0, total + offset) : offset
            guard actualOffset < total else { return Data() }
            let upper = min(actualOffset + length, total)
            return data.subdata(in: Int(actualOffset)..<Int(upper))
        default:
            throw SourceError.connectionFailed("Ugreen range request failed: HTTP \(http.statusCode)")
        }
    }

    func streamData(for path: String) async throws -> AsyncThrowingStream<Data, Error> {
        let local = try await localURL(for: path)
        return AsyncThrowingStream { c in
            Task {
                let h = try FileHandle(forReadingFrom: local); defer { h.closeFile() }
                while true { let d = h.readData(ofLength: 65536); if d.isEmpty { break }; c.yield(d) }
                c.finish()
            }
        }
    }

    func scanAudioFiles(from path: String) async throws -> AsyncThrowingStream<RemoteFileItem, Error> {
        AsyncThrowingStream { c in
            Task { try await scan(path: path, c: c); c.finish() }
        }
    }

    private func scan(path: String, c: AsyncThrowingStream<RemoteFileItem, Error>.Continuation) async throws {
        let items = try await listFiles(at: path)
        for item in items {
            if item.isDirectory { try await scan(path: item.path, c: c) }
            else if PrimuseConstants.supportedAudioExtensions.contains(
                (item.name as NSString).pathExtension.lowercased()) { c.yield(item) }
        }
    }
}
