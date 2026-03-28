import Foundation
import FilesProvider
import PrimuseKit

actor WebDAVSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let username: String
    private let password: String
    private var provider: WebDAVFileProvider?
    private let cacheDirectory: URL

    init(sourceID: String, host: String, port: Int? = nil, username: String, password: String) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.username = username
        self.password = password

        let cacheDir = FileManager.default.temporaryDirectory.appendingPathComponent("primuse_webdav_cache")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        var urlString = host
        if !urlString.hasPrefix("http") {
            urlString = "https://\(urlString)"
        }
        if let port {
            // Insert port before path
            if let url = URL(string: urlString) {
                var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
                components?.port = port
                urlString = components?.string ?? urlString
            }
        }

        guard let serverURL = URL(string: urlString) else {
            throw SourceError.connectionFailed("Invalid WebDAV URL")
        }

        let credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )

        provider = WebDAVFileProvider(baseURL: serverURL, credential: credential)

        // Test connection
        _ = try await listFiles(at: "/")
    }

    func disconnect() async {
        provider = nil
    }

    func listFiles(at path: String) async throws -> [RemoteFileItem] {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        return try await withCheckedThrowingContinuation { continuation in
            provider.contentsOfDirectory(path: path) { contents, error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
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

    func localURL(for path: String) async throws -> URL {
        guard let provider else { throw SourceError.connectionFailed("Not connected") }

        let localPath = cacheDirectory.appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "_")
        )

        if FileManager.default.fileExists(atPath: localPath.path) {
            return localPath
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.copyItem(path: path, toLocalURL: localPath) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: localPath)
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
            } else {
                let ext = (item.name as NSString).pathExtension.lowercased()
                if PrimuseConstants.supportedAudioExtensions.contains(ext) {
                    continuation.yield(item)
                }
            }
        }
    }
}
