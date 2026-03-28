import FilesProvider
import Foundation
import PrimuseKit

actor FTPSource: MusicSourceConnector {
    let sourceID: String
    private let host: String
    private let port: Int?
    private let basePath: String?
    private let username: String
    private let password: String
    private let encryption: FTPEncryption
    private var provider: FTPFileProvider?
    private let cacheDirectory: URL

    init(
        sourceID: String,
        host: String,
        port: Int? = nil,
        basePath: String? = nil,
        username: String,
        password: String,
        encryption: FTPEncryption
    ) {
        self.sourceID = sourceID
        self.host = host
        self.port = port
        self.basePath = basePath
        self.username = username
        self.password = password
        self.encryption = encryption

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("primuse_ftp_cache")
            .appendingPathComponent(sourceID)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.cacheDirectory = cacheDir
    }

    func connect() async throws {
        if provider != nil {
            return
        }

        let credential = URLCredential(
            user: username,
            password: password,
            persistence: .forSession
        )

        guard let provider = FTPFileProvider(
            baseURL: try serverURL(),
            credential: credential
        ) else {
            throw SourceError.connectionFailed("Invalid FTP URL")
        }

        provider.securedDataConnection = encryption != .none
        self.provider = provider

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
                    .map { file in
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

        let localURL = cacheDirectory.appendingPathComponent(
            path.replacingOccurrences(of: "/", with: "_")
        )

        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            provider.copyItem(path: path, toLocalURL: localURL) { error in
                if let error {
                    continuation.resume(throwing: SourceError.connectionFailed(error.localizedDescription))
                } else {
                    continuation.resume(returning: localURL)
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

    private func serverURL() throws -> URL {
        let scheme = switch encryption {
        case .none: "ftp"
        case .implicitTLS: "ftps"
        case .explicitTLS: "ftpes"
        }

        let rawHost = host.contains("://") ? host : "\(scheme)://\(host)"
        guard var components = URLComponents(string: rawHost) else {
            throw SourceError.connectionFailed("Invalid FTP host")
        }

        components.scheme = scheme
        components.port = port ?? defaultPort

        if let basePath, !basePath.isEmpty {
            components.path = normalizedBasePath(basePath)
        } else if components.path.isEmpty {
            components.path = "/"
        }

        guard let url = components.url else {
            throw SourceError.connectionFailed("Invalid FTP URL")
        }
        return url
    }

    private var defaultPort: Int {
        switch encryption {
        case .implicitTLS:
            return 990
        case .none, .explicitTLS:
            return 21
        }
    }

    private func normalizedBasePath(_ path: String) -> String {
        path.hasPrefix("/") ? path : "/\(path)"
    }
}
