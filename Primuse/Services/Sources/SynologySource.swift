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
        sourceID: String,
        host: String,
        port: Int,
        useSsl: Bool,
        username: String,
        password: String,
        rememberDevice: Bool,
        deviceId: String?
    ) {
        self.sourceID = sourceID
        self.api = SynologyAPI(host: host, port: port, useSsl: useSsl)
        self.username = username
        self.password = password
        self.rememberDevice = rememberDevice
        self.deviceId = deviceId

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_synology_cache_\(sourceID)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        guard await api.isLoggedIn == false else { return }

        let result = await api.login(
            account: username,
            password: password,
            deviceName: rememberDevice ? "Primuse-iOS" : nil,
            deviceId: deviceId
        )

        if result.success == false {
            if result.needs2FA {
                throw SourceError.authenticationFailed
            }
            throw SourceError.connectionFailed(result.errorMessage ?? "Synology login failed")
        }
    }

    func disconnect() async {
        await api.logout()
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        try await connect()
        return try await api.listDirectory(path: path).map {
            RemoteFileItem(
                name: $0.name,
                path: $0.path,
                isDirectory: $0.isDirectory,
                size: $0.size,
                modifiedDate: nil
            )
        }
    }

    func localURL(for path: String) async throws -> URL {
        try await connect()

        let sanitized = path.replacingOccurrences(of: "/", with: "_")
        let fileURL = cacheDirectory.appendingPathComponent(sanitized)

        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL
        }

        let data = try await api.downloadFile(path: path)
        try data.write(to: fileURL, options: .atomic)
        return fileURL
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
}
