import Foundation
import PrimuseKit

actor QnapSource: MusicSourceConnector {
    let sourceID: String
    private let api: QnapAPI
    private let username: String
    private let password: String
    private let cacheDirectory: URL

    init(sourceID: String, host: String, port: Int, useSsl: Bool,
         username: String, password: String) {
        self.sourceID = sourceID
        self.api = QnapAPI(host: host, port: port, useSsl: useSsl)
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
                             : SourceError.connectionFailed(r.errorMessage ?? "QNAP login failed")
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
        let session = URLSession(configuration: config, delegate: InsecureURLSessionDelegate(), delegateQueue: nil)
        let (tempURL, _) = try await session.download(from: url)
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: tempURL, to: fileURL)
        return fileURL
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
